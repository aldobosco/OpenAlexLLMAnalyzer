# Pipeline scripts

Put deterministic command-line scripts in the appropriate stage directory. Each script must accept configuration from environment variables or explicit arguments, write only to its assigned data layer, and log record counts.

- `extract/`: OpenAlex API acquisition; raw response plus run metadata.
- `transform/`: normalization, deduplication, validation, and processed outputs.
- `load/`: PostgreSQL, Neo4j, and warehouse loaders.
- `evaluation/`: repeatable query timing and comparison collection.
