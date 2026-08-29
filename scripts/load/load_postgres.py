from __future__ import annotations

import argparse
import os
from pathlib import Path

import psycopg
from psycopg import sql

TABLES = [
    ("works", "works.csv"),
    ("authors", "authors.csv"),
    ("institutions", "institutions.csv"),
    ("sources", "sources.csv"),
    ("topics", "topics.csv"),
    ("authorships", "authorships.csv"),
    ("affiliations", "affiliations.csv"),
    ("work_topics", "work_topics.csv"),
    ("work_sources", "work_sources.csv"),
    ("citations", "citations.csv"),
]


def connection_string() -> str:
    return os.environ.get(
        "DATABASE_URL",
        "postgresql://openalex:openalex@localhost:5432/openalex",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Load reconciled OpenAlex CSV data into PostgreSQL.")
    parser.add_argument("--processed-dir", type=Path, default=Path("data/processed"))
    parser.add_argument("--schema", default="openalex")
    args = parser.parse_args()

    for _, filename in TABLES:
        path = args.processed_dir / filename
        if not path.is_file():
            raise SystemExit(f"Required processed file not found: {path}")

    with psycopg.connect(connection_string()) as conn:
        with conn.cursor() as cur:
            cur.execute(sql.SQL("SET search_path TO {}, public").format(sql.Identifier(args.schema)))
            for table, filename in TABLES:
                path = args.processed_dir / filename
                statement = sql.SQL("COPY {} FROM STDIN WITH (FORMAT CSV, HEADER TRUE, NULL '')").format(
                    sql.Identifier(table)
                )
                with path.open("r", encoding="utf-8", newline="") as handle:
                    with cur.copy(statement) as copy:
                        while chunk := handle.read(1024 * 1024):
                            copy.write(chunk)
                cur.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table)))
                count = cur.fetchone()[0]
                print(f"Loaded {table}: {count} rows")
        conn.commit()


if __name__ == "__main__":
    main()