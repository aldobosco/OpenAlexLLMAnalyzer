# Local setup and verification

## Prerequisites

Install Git, Docker Desktop (with Docker Compose v2), and Python 3.11 or newer. Confirm with `git --version`, `docker compose version`, and `python --version`.

## Configure secrets

Copy `.env.example` to `.env`; set strong, unique local passwords. The `.env` file is intentionally ignored by Git.

## Start databases

```bash
docker compose --env-file .env -f docker/compose.yaml up -d
docker compose --env-file .env -f docker/compose.yaml ps
docker compose --env-file .env -f docker/compose.yaml exec postgres pg_isready -U openalex_app -d openalex
```

Expected services: `postgres` should report `healthy`; Neo4j Browser is available at `http://localhost:${NEO4J_HTTP_PORT}` (normally 7474), and Bolt on 7687.

## Python environment

```bash
python -m venv .venv
source .venv/bin/activate  # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install --upgrade pip
pip install -r requirements.txt
ruff check .
pytest
```

## Reset policy

Use `docker compose --env-file .env -f docker/compose.yaml down` to stop services while retaining data. Use `down -v` only for a deliberate clean reset; it removes both database volumes.
