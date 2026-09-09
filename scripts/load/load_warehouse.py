# ruff: noqa: E501

from __future__ import annotations

import argparse
import csv
import os
from datetime import date
from pathlib import Path
from typing import Any

import psycopg

REQUIRED_FILES = (
    "works.csv",
    "authors.csv",
    "institutions.csv",
    "sources.csv",
    "topics.csv",
    "authorships.csv",
    "affiliations.csv",
    "work_topics.csv",
    "work_sources.csv",
    "citations.csv",
)


from dotenv import load_dotenv

load_dotenv()


def connection_string() -> str:
    if "DATABASE_URL" in os.environ:
        return os.environ["DATABASE_URL"]
    user = os.getenv("POSTGRES_USER", "openalex_app")
    password = os.getenv("POSTGRES_PASSWORD", "openalex")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    db = os.getenv("POSTGRES_DB", "openalex")
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def value(row: dict[str, str], column: str) -> str | None:
    result = (row.get(column) or "").strip()
    return result or None


def integer(row: dict[str, str], column: str) -> int | None:
    raw = value(row, column)
    return int(raw) if raw is not None else None


def boolean(row: dict[str, str], column: str) -> bool | None:
    raw = value(row, column)
    return {"true": True, "false": False}.get(raw.lower()) if raw else None


def dimension_map(cur: Any, table: str, natural_column: str) -> dict[str, int]:
    cur.execute(f"SELECT {natural_column}, {table.removeprefix('dim_')}_key FROM {table}")
    return {natural_id: key for natural_id, key in cur.fetchall()}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Load processed OpenAlex CSVs into the warehouse star schema."
    )
    parser.add_argument("--processed-dir", type=Path, default=Path("data/processed"))
    parser.add_argument(
        "--reset", action="store_true", help="Truncate warehouse tables before loading."
    )
    args = parser.parse_args()

    missing = [name for name in REQUIRED_FILES if not (args.processed_dir / name).is_file()]
    if missing:
        raise SystemExit(f"Missing processed CSV files: {', '.join(missing)}")

    rows = {name: read_csv(args.processed_dir / name) for name in REQUIRED_FILES}
    source_for_work = {row["work_id"]: row["source_id"] for row in rows["work_sources.csv"]}

    with psycopg.connect(connection_string()) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO warehouse, public")
            if args.reset:
                cur.execute(
                    "TRUNCATE bridge_work_topic, bridge_work_author, bridge_work_institution, bridge_work_citation, fact_work, "
                    "dim_date, dim_source, dim_work_type, dim_topic, dim_author, dim_institution RESTART IDENTITY"
                )

            cur.execute("INSERT INTO dim_date (date_key) VALUES (0) ON CONFLICT DO NOTHING")
            cur.execute(
                "INSERT INTO dim_source (source_key, source_id, display_name) VALUES (0, NULL, 'Unknown source') ON CONFLICT DO NOTHING"
            )
            for row in rows["sources.csv"]:
                cur.execute(
                    "INSERT INTO dim_source (source_id, display_name, source_type, issn_l, issn, publisher) "
                    "VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (source_id) DO UPDATE SET "
                    "display_name = EXCLUDED.display_name, source_type = EXCLUDED.source_type, "
                    "issn_l = EXCLUDED.issn_l, issn = EXCLUDED.issn, publisher = EXCLUDED.publisher",
                    tuple(
                        value(row, field)
                        for field in (
                            "source_id",
                            "display_name",
                            "source_type",
                            "issn_l",
                            "issn",
                            "publisher",
                        )
                    ),
                )
            for row in rows["topics.csv"]:
                cur.execute(
                    "INSERT INTO dim_topic (topic_id, display_name, subfield_id, subfield_name, field_id, field_name, domain_id, domain_name) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (topic_id) DO UPDATE SET "
                    "display_name = EXCLUDED.display_name, subfield_id = EXCLUDED.subfield_id, subfield_name = EXCLUDED.subfield_name, "
                    "field_id = EXCLUDED.field_id, field_name = EXCLUDED.field_name, domain_id = EXCLUDED.domain_id, domain_name = EXCLUDED.domain_name",
                    tuple(
                        value(row, field)
                        for field in (
                            "topic_id",
                            "display_name",
                            "subfield_id",
                            "subfield_name",
                            "field_id",
                            "field_name",
                            "domain_id",
                            "domain_name",
                        )
                    ),
                )
            for row in rows["authors.csv"]:
                cur.execute(
                    "INSERT INTO dim_author (author_id, display_name) VALUES (%s, %s) ON CONFLICT (author_id) DO UPDATE SET display_name = EXCLUDED.display_name",
                    (value(row, "author_id"), value(row, "display_name")),
                )
            for row in rows["institutions.csv"]:
                cur.execute(
                    "INSERT INTO dim_institution (institution_id, display_name, country_code, institution_type) VALUES (%s, %s, %s, %s) "
                    "ON CONFLICT (institution_id) DO UPDATE SET display_name = EXCLUDED.display_name, country_code = EXCLUDED.country_code, institution_type = EXCLUDED.institution_type",
                    tuple(
                        value(row, field)
                        for field in (
                            "institution_id",
                            "display_name",
                            "country_code",
                            "institution_type",
                        )
                    ),
                )
            for work_type in sorted(
                {value(row, "work_type") for row in rows["works.csv"] if value(row, "work_type")}
            ):
                cur.execute(
                    "INSERT INTO dim_work_type (work_type) VALUES (%s) ON CONFLICT DO NOTHING",
                    (work_type,),
                )

            for row in rows["works.csv"]:
                raw_date = value(row, "publication_date")
                if raw_date:
                    parsed = date.fromisoformat(raw_date)
                    date_key = parsed.year * 10_000 + parsed.month * 100 + parsed.day
                    cur.execute(
                        "INSERT INTO dim_date (date_key, full_date, day_of_month, month_number, month_name, quarter_number, year) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (date_key) DO NOTHING",
                        (
                            date_key,
                            parsed,
                            parsed.day,
                            parsed.month,
                            parsed.strftime("%B"),
                            (parsed.month - 1) // 3 + 1,
                            parsed.year,
                        ),
                    )

            source_keys = dimension_map(cur, "dim_source", "source_id")
            type_keys = dimension_map(cur, "dim_work_type", "work_type")
            for row in rows["works.csv"]:
                raw_date = value(row, "publication_date")
                parsed = date.fromisoformat(raw_date) if raw_date else None
                date_key = parsed.year * 10_000 + parsed.month * 100 + parsed.day if parsed else 0
                cur.execute(
                    "INSERT INTO fact_work (work_id, date_key, source_key, work_type_key, publication_year, cited_by_count, is_oa, oa_status) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (work_id) DO UPDATE SET "
                    "date_key = EXCLUDED.date_key, source_key = EXCLUDED.source_key, work_type_key = EXCLUDED.work_type_key, "
                    "publication_year = EXCLUDED.publication_year, cited_by_count = EXCLUDED.cited_by_count, "
                    "is_oa = EXCLUDED.is_oa, oa_status = EXCLUDED.oa_status",
                    (
                        value(row, "work_id"),
                        date_key,
                        source_keys.get(source_for_work.get(row["work_id"]), 0),
                        type_keys[row["work_type"]],
                        integer(row, "publication_year"),
                        integer(row, "cited_by_count") or 0,
                        boolean(row, "is_oa"),
                        value(row, "oa_status"),
                    ),
                )

            cur.execute("SELECT work_id, work_key FROM fact_work")
            work_keys = dict(cur.fetchall())
            topic_keys = dimension_map(cur, "dim_topic", "topic_id")
            author_keys = dimension_map(cur, "dim_author", "author_id")
            institution_keys = dimension_map(cur, "dim_institution", "institution_id")
            if args.reset:
                pass
            else:
                cur.execute("DELETE FROM bridge_work_topic")
                cur.execute("DELETE FROM bridge_work_author")
                cur.execute("DELETE FROM bridge_work_institution")
                cur.execute("DELETE FROM bridge_work_citation")
            cur.executemany(
                "INSERT INTO bridge_work_topic (work_key, topic_key, topic_score, is_primary_topic) VALUES (%s, %s, %s, %s)",
                [
                    (
                        work_keys[row["work_id"]],
                        topic_keys[row["topic_id"]],
                        value(row, "score"),
                        boolean(row, "is_primary_topic") or False,
                    )
                    for row in rows["work_topics.csv"]
                ],
            )
            cur.executemany(
                "INSERT INTO bridge_work_author (work_key, author_key, author_position, author_order, is_corresponding) VALUES (%s, %s, %s, %s, %s)",
                [
                    (
                        work_keys[row["work_id"]],
                        author_keys[row["author_id"]],
                        value(row, "author_position"),
                        integer(row, "author_order"),
                        boolean(row, "is_corresponding"),
                    )
                    for row in rows["authorships.csv"]
                ],
            )
            distinct_affiliations = {
                (row["work_id"], row["institution_id"]) for row in rows["affiliations.csv"]
            }
            cur.executemany(
                "INSERT INTO bridge_work_institution (work_key, institution_key) VALUES (%s, %s)",
                [
                    (work_keys[work_id], institution_keys[institution_id])
                    for work_id, institution_id in sorted(distinct_affiliations)
                ],
            )
            cur.executemany(
                "INSERT INTO bridge_work_citation (citing_work_key, cited_work_key) VALUES (%s, %s)",
                [
                    (work_keys[row["citing_work_id"]], work_keys[row["cited_work_id"]])
                    for row in rows["citations.csv"]
                ],
            )
            cur.execute("ANALYZE")
            for table in (
                "dim_date",
                "dim_source",
                "dim_work_type",
                "dim_topic",
                "dim_author",
                "dim_institution",
                "fact_work",
                "bridge_work_topic",
                "bridge_work_author",
                "bridge_work_institution",
                "bridge_work_citation",
            ):
                cur.execute(f"SELECT count(*) FROM {table}")
                print(f"Loaded {table}: {cur.fetchone()[0]} rows")
        conn.commit()


if __name__ == "__main__":
    main()
