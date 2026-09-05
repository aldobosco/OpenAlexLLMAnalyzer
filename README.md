# OpenAlex: Relational, Graph, and Data Warehouse Analysis

This repository implements a reproducible comparison of PostgreSQL, Neo4j, and a relational data warehouse over a bounded OpenAlex subset. The pipeline will extract and reconcile scholarly works and their authors, institutions, topics, sources, and citations; load equivalent relational and graph models; and compare SQL, Cypher, and OLAP analyses.

## Status

Dataset scope and analytical questions are tracked in `docs/scope.md` and must be finalized before extraction.

## Repository layout

```text
data/                 # raw, staging, and reconciled data (not versioned)
docs/                 # scope, setup, conventions, and later diagrams
notebooks/            # exploratory work only
scripts/              # extract, transform, load, evaluation
sql/relational/       # PostgreSQL DDL, loads, and SQL queries
sql/warehouse/        # DFM-derived warehouse DDL and OLAP queries
cypher/               # Neo4j schema, load, and Cypher queries
tests/                # automated data-quality and ETL tests
docker/               # local PostgreSQL + Neo4j stack
```

## Quick start

1. Install Docker Desktop, Git, and Python 3.11+.
2. Copy the example configuration: `cp .env.example .env`. Replace both placeholder passwords.
3. Start databases: `docker compose --env-file .env -f docker/compose.yaml up -d`.
4. Verify PostgreSQL: `docker compose --env-file .env -f docker/compose.yaml exec postgres pg_isready -U openalex_app -d openalex`.
5. Open Neo4j Browser at `http://localhost:7474` and log in with the credentials in `.env`.
6. Create the Python environment and install tools:
   ```bash
   python -m venv .venv
   source .venv/bin/activate  # Windows PowerShell: .venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   ruff check .
   pytest
   ```

Stop services with `docker compose --env-file .env -f docker/compose.yaml down`. Add `-v` only when you deliberately want to delete database volumes.

## Reproducibility rules

- Do not commit `.env`, full raw data, derived data, logs, or database dumps.
- Keep source responses unchanged in `data/raw/`; create outputs only in `data/staging/` or `data/processed/`.
- Record extraction parameters, source/version, timestamp, pagination state, and counts with each run.
- Run formatting/linting and tests before opening a pull request.

See `docs/local-setup.md` and `docs/warehouse-model.md`.
