from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
from typing import Any, Callable

from neo4j import GraphDatabase

BATCH_SIZE = 1_000

NODE_FILES = {
    "works.csv": ("Work", "work_id", {
        "doi": str, "title": str, "abstract": str, "publication_date": str,
        "publication_year": int, "work_type": str, "language": str,
        "cited_by_count": int, "is_oa": bool, "oa_status": str,
    }),
    "authors.csv": ("Author", "author_id", {"display_name": str}),
    "institutions.csv": ("Institution", "institution_id", {
        "display_name": str, "country_code": str, "institution_type": str,
    }),
    "sources.csv": ("Source", "source_id", {
        "display_name": str, "source_type": str, "issn_l": str,
        "issn": str, "publisher": str,
    }),
    "topics.csv": ("Topic", "topic_id", {
        "display_name": str, "subfield_id": str, "subfield_name": str,
        "field_id": str, "field_name": str, "domain_id": str, "domain_name": str,
    }),
}

RELATIONSHIP_FILES = {
    "authorships.csv": """
        UNWIND $rows AS row
        MATCH (a:Author {id: row.author_id})
        MATCH (w:Work {id: row.work_id})
        MERGE (a)-[r:AUTHORED]->(w)
        SET r.author_position = row.author_position,
            r.author_order = row.author_order,
            r.is_corresponding = row.is_corresponding
        RETURN count(r) AS loaded
    """,
    "affiliations.csv": """
        UNWIND $rows AS row
        MATCH (a:Author {id: row.author_id})
        MATCH (i:Institution {id: row.institution_id})
        MATCH (:Work {id: row.work_id})
        MERGE (a)-[r:AFFILIATED_WITH {work_id: row.work_id}]->(i)
        RETURN count(r) AS loaded
    """,
    "work_topics.csv": """
        UNWIND $rows AS row
        MATCH (w:Work {id: row.work_id})
        MATCH (t:Topic {id: row.topic_id})
        MERGE (w)-[r:HAS_TOPIC]->(t)
        SET r.score = row.score,
            r.is_primary_topic = row.is_primary_topic
        RETURN count(r) AS loaded
    """,
    "work_sources.csv": """
        UNWIND $rows AS row
        MATCH (w:Work {id: row.work_id})
        MATCH (s:Source {id: row.source_id})
        MERGE (w)-[r:PUBLISHED_IN {location_role: row.location_role}]->(s)
        RETURN count(r) AS loaded
    """,
    "citations.csv": """
        UNWIND $rows AS row
        MATCH (citing:Work {id: row.citing_work_id})
        MATCH (cited:Work {id: row.cited_work_id})
        WHERE citing <> cited
        MERGE (citing)-[r:CITES]->(cited)
        RETURN count(r) AS loaded
    """,
}

CONSTRAINTS = [
    "CREATE CONSTRAINT work_id_unique IF NOT EXISTS FOR (n:Work) REQUIRE n.id IS UNIQUE",
    "CREATE CONSTRAINT author_id_unique IF NOT EXISTS FOR (n:Author) REQUIRE n.id IS UNIQUE",
    "CREATE CONSTRAINT institution_id_unique IF NOT EXISTS FOR (n:Institution) REQUIRE n.id IS UNIQUE",
    "CREATE CONSTRAINT source_id_unique IF NOT EXISTS FOR (n:Source) REQUIRE n.id IS UNIQUE",
    "CREATE CONSTRAINT topic_id_unique IF NOT EXISTS FOR (n:Topic) REQUIRE n.id IS UNIQUE",
    "CREATE INDEX work_publication_year IF NOT EXISTS FOR (n:Work) ON (n.publication_year)",
    "CREATE INDEX work_type_year IF NOT EXISTS FOR (n:Work) ON (n.work_type, n.publication_year)",
    "CREATE INDEX work_citations IF NOT EXISTS FOR (n:Work) ON (n.cited_by_count)",
]

RELATIONSHIP_CONVERTERS: dict[str, dict[str, Callable[[str], Any]]] = {
    "authorships.csv": {"author_position": str, "author_order": int, "is_corresponding": bool},
    "affiliations.csv": {},
    "work_topics.csv": {"score": float, "is_primary_topic": bool},
    "work_sources.csv": {"location_role": str},
    "citations.csv": {},
}


def optional(value: str | None, converter: Callable[[str], Any]) -> Any:
    if value is None or value.strip() == "":
        return None
    if converter is bool:
        return value.strip().lower() in {"true", "t", "1", "yes", "y"}
    return converter(value.strip())


def read_rows(path: Path, converters: dict[str, Callable[[str], Any]]) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = []
        for raw in csv.DictReader(handle):
            rows.append({key: optional(value, converters.get(key, str)) for key, value in raw.items()})
    return rows


def chunks(rows: list[dict[str, Any]], size: int = BATCH_SIZE):
    for start in range(0, len(rows), size):
        yield rows[start : start + size]


def scalar(tx, query: str, **params: Any) -> int:
    record = tx.run(query, **params).single()
    return int(record["loaded"])


def create_constraints(session) -> None:
    for statement in CONSTRAINTS:
        session.run(statement).consume()


def reset_graph(session) -> None:
    session.run("MATCH (n) DETACH DELETE n").consume()


def load_nodes(session, processed_dir: Path, filename: str, label: str, id_column: str,
               properties: dict[str, Callable[[str], Any]]) -> int:
    rows = read_rows(processed_dir / filename, {id_column: str, **properties})
    query = f"""
        UNWIND $rows AS row
        MERGE (n:{label} {{id: row.id}})
        SET n += row.properties
        RETURN count(n) AS loaded
    """
    total = 0
    for batch in chunks(rows):
        payload = [
            {"id": row[id_column], "properties": {key: value for key, value in row.items()
                                                      if key != id_column and value is not None}}
            for row in batch
        ]
        total += session.execute_write(scalar, query, rows=payload)
    if total != len(rows):
        raise RuntimeError(f"{filename}: loaded {total}, expected {len(rows)}")
    return total


def load_relationships(session, processed_dir: Path, filename: str) -> int:
    rows = read_rows(processed_dir / filename, RELATIONSHIP_CONVERTERS[filename])
    total = 0
    for batch in chunks(rows):
        total += session.execute_write(scalar, RELATIONSHIP_FILES[filename], rows=batch)
    if total != len(rows):
        raise RuntimeError(
            f"{filename}: loaded {total}, expected {len(rows)}. "
            "An endpoint is missing, a self-loop was rejected, or CSV keys are invalid."
        )
    return total


def main() -> None:
    parser = argparse.ArgumentParser(description="Load reconciled OpenAlex CSVs into Neo4j.")
    parser.add_argument("--processed-dir", type=Path, default=Path("data/processed"))
    parser.add_argument("--uri", default=os.getenv("NEO4J_URI", "bolt://localhost:7687"))
    parser.add_argument("--user", default=os.getenv("NEO4J_USER", "neo4j"))
    parser.add_argument("--password", default=os.getenv("NEO4J_PASSWORD"))
    parser.add_argument("--database", default=os.getenv("NEO4J_DATABASE", "neo4j"))
    parser.add_argument("--reset", action="store_true", help="Delete all graph nodes and relationships first.")
    args = parser.parse_args()

    if not args.password:
        raise SystemExit("Set NEO4J_PASSWORD or pass --password.")
    if not args.processed_dir.is_dir():
        raise SystemExit(f"Processed directory not found: {args.processed_dir}")

    expected_files = [*NODE_FILES, *RELATIONSHIP_FILES]
    missing = [name for name in expected_files if not (args.processed_dir / name).is_file()]
    if missing:
        raise SystemExit(f"Missing processed CSV files: {', '.join(missing)}")

    summary: dict[str, int] = {}
    with GraphDatabase.driver(args.uri, auth=(args.user, args.password)) as driver:
        driver.verify_connectivity()
        with driver.session(database=args.database) as session:
            create_constraints(session)
            if args.reset:
                reset_graph(session)
            for filename, (label, id_column, properties) in NODE_FILES.items():
                summary[filename] = load_nodes(session, args.processed_dir, filename, label, id_column, properties)
            for filename in RELATIONSHIP_FILES:
                summary[filename] = load_relationships(session, args.processed_dir, filename)

    report_path = args.processed_dir / "neo4j_load_report.json"
    report_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()