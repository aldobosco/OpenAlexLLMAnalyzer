"""
Example:
  python scripts/transform/run_etl.py \
    --run-dir data/raw/openalex/20260826T133818Z \
    --processed-dir data/processed
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from tempfile import mkdtemp
from typing import Any

WORK_COLUMNS = [
    "work_id", "doi", "title", "abstract", "publication_date", "publication_year",
    "work_type", "language", "cited_by_count", "is_oa", "oa_status",
]
ENTITY_COLUMNS = {
    "authors.csv": ["author_id", "display_name"],
    "institutions.csv": ["institution_id", "display_name", "country_code", "institution_type"],
    "sources.csv": ["source_id", "display_name", "source_type", "issn_l", "issn", "publisher"],
    "topics.csv": [
        "topic_id", "display_name", "subfield_id", "subfield_name", "field_id",
        "field_name", "domain_id", "domain_name",
    ],
}
RELATION_COLUMNS = {
    "authorships.csv": ["work_id", "author_id", "author_position", "author_order", "is_corresponding"],
    "affiliations.csv": ["work_id", "author_id", "institution_id"],
    "work_topics.csv": ["work_id", "topic_id", "score", "is_primary_topic"],
    "work_sources.csv": ["work_id", "source_id", "location_role"],
    "citations.csv": ["citing_work_id", "cited_work_id"],
}


def openalex_id(value: str | None) -> str | None:
    if not value:
        return None
    result = str(value).rstrip("/").rsplit("/", 1)[-1].strip()
    return result or None


def clean_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def reconstruct_abstract(index: dict[str, list[int]] | None) -> str:
    if not isinstance(index, dict):
        return ""
    positions: dict[int, str] = {}
    for token, indexes in index.items():
        if not isinstance(indexes, list):
            continue
        for position in indexes:
            if isinstance(position, int):
                positions[position] = str(token)
    return " ".join(positions[position] for position in sorted(positions))


def bool_csv(value: Any) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    return ""


def integer_csv(value: Any) -> str:
    try:
        return str(int(value))
    except (TypeError, ValueError):
        return ""


def float_csv(value: Any) -> str:
    try:
        return format(float(value), ".12g")
    except (TypeError, ValueError):
        return ""


def valid_date(value: Any) -> str:
    text = clean_text(value)
    if not text:
        return ""
    try:
        datetime.strptime(text, "%Y-%m-%d")
        return text
    except ValueError:
        return ""


def selected_ids_from_manifest(manifest: dict[str, Any]) -> set[str]:
    by_year = manifest.get("selected_work_ids_by_year")
    if not isinstance(by_year, dict):
        raise ValueError("scope_manifest.json has no selected_work_ids_by_year object")
    result = {openalex_id(work_id) for ids in by_year.values() for work_id in (ids or [])}
    result.discard(None)
    if not result:
        raise ValueError("scope manifest contains no selected work IDs")
    return result


def merge_nonempty(target: dict[str, str], incoming: dict[str, str]) -> None:
    for key, value in incoming.items():
        if not target.get(key) and value:
            target[key] = value


def write_csv(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="raise")
        writer.writeheader()
        writer.writerows(rows)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def topic_row(topic: dict[str, Any]) -> tuple[str | None, dict[str, str]]:
    topic_id = openalex_id(topic.get("id"))
    if not topic_id:
        return None, {}
    subfield = topic.get("subfield") or {}
    field = topic.get("field") or {}
    domain = topic.get("domain") or {}
    return topic_id, {
        "topic_id": topic_id,
        "display_name": clean_text(topic.get("display_name")),
        "subfield_id": clean_text(subfield.get("id")),
        "subfield_name": clean_text(subfield.get("display_name")),
        "field_id": clean_text(field.get("id")),
        "field_name": clean_text(field.get("display_name")),
        "domain_id": clean_text(domain.get("id")),
        "domain_name": clean_text(domain.get("display_name")),
    }


def transform(run_dir: Path, processed_dir: Path) -> dict[str, Any]:
    manifest_path = run_dir / "scope_manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Missing {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    selected_ids = selected_ids_from_manifest(manifest)
    response_paths = sorted((run_dir / "responses").glob("*.json"))
    if not response_paths:
        raise FileNotFoundError(f"No JSON pages found in {run_dir / 'responses'}")

    quality: Counter[str] = Counter()
    works_by_id: dict[str, dict[str, Any]] = {}
    raw_pages_read = 0
    raw_work_records = 0

    for page_path in response_paths:
        page = json.loads(page_path.read_text(encoding="utf-8"))
        raw_pages_read += 1
        for work in page.get("results", []) or []:
            raw_work_records += 1
            work_id = openalex_id((work or {}).get("id"))
            if work_id not in selected_ids:
                continue
            if work_id in works_by_id:
                quality["duplicate_selected_work_records_removed"] += 1
                continue
            works_by_id[work_id] = work

    missing_selected = sorted(selected_ids - set(works_by_id))
    if missing_selected:
        raise ValueError(
            f"{len(missing_selected)} selected IDs are absent from raw response pages; refusing partial ETL. "
            f"Examples: {', '.join(missing_selected[:5])}"
        )

    authors: dict[str, dict[str, str]] = {}
    institutions: dict[str, dict[str, str]] = {}
    sources: dict[str, dict[str, str]] = {}
    topics: dict[str, dict[str, str]] = {}
    works: list[dict[str, str]] = []
    authorships: set[tuple[str, str, str, str, str]] = set()
    affiliations: set[tuple[str, str, str]] = set()
    work_topics: set[tuple[str, str, str, str]] = set()
    work_sources: set[tuple[str, str, str]] = set()
    citations: set[tuple[str, str]] = set()

    for work_id in sorted(works_by_id):
        work = works_by_id[work_id]
        date = valid_date(work.get("publication_date"))
        if work.get("publication_date") and not date:
            quality["invalid_publication_dates_normalized_to_null"] += 1
        oa = work.get("open_access") or {}
        works.append({
            "work_id": work_id,
            "doi": clean_text(work.get("doi")),
            "title": clean_text(work.get("title")),
            "abstract": clean_text(reconstruct_abstract(work.get("abstract_inverted_index"))),
            "publication_date": date,
            "publication_year": integer_csv(work.get("publication_year")),
            "work_type": clean_text(work.get("type")),
            "language": clean_text(work.get("language")),
            "cited_by_count": integer_csv(work.get("cited_by_count")),
            "is_oa": bool_csv(oa.get("is_oa")),
            "oa_status": clean_text(oa.get("oa_status")),
        })

        for order, authorship in enumerate(work.get("authorships") or [], start=1):
            author = authorship.get("author") or {}
            author_id = openalex_id(author.get("id"))
            if not author_id:
                quality["authorships_discarded_missing_author_id"] += 1
                continue
            author_row = {"author_id": author_id, "display_name": clean_text(author.get("display_name"))}
            if author_id not in authors:
                authors[author_id] = author_row
            else:
                merge_nonempty(authors[author_id], author_row)
            authorships.add((
                work_id, author_id, clean_text(authorship.get("author_position")), str(order),
                bool_csv(authorship.get("is_corresponding")),
            ))
            for institution in authorship.get("institutions") or []:
                institution_id = openalex_id(institution.get("id"))
                if not institution_id:
                    quality["affiliations_discarded_missing_institution_id"] += 1
                    continue
                institution_row = {
                    "institution_id": institution_id,
                    "display_name": clean_text(institution.get("display_name")),
                    "country_code": clean_text(institution.get("country_code")),
                    "institution_type": clean_text(institution.get("type")),
                }
                if institution_id not in institutions:
                    institutions[institution_id] = institution_row
                else:
                    merge_nonempty(institutions[institution_id], institution_row)
                affiliations.add((work_id, author_id, institution_id))

        location = work.get("primary_location") or {}
        source = location.get("source") or {}
        source_id = openalex_id(source.get("id"))
        if source_id:
            raw_issn = source.get("issn") or []
            issn = ";".join(clean_text(item) for item in raw_issn if clean_text(item)) if isinstance(raw_issn, list) else clean_text(raw_issn)
            source_row = {
                "source_id": source_id,
                "display_name": clean_text(source.get("display_name")),
                "source_type": clean_text(source.get("type")),
                "issn_l": clean_text(source.get("issn_l")),
                "issn": issn,
                "publisher": clean_text(source.get("host_organization_name")),
            }
            if source_id not in sources:
                sources[source_id] = source_row
            else:
                merge_nonempty(sources[source_id], source_row)
            work_sources.add((work_id, source_id, "primary_location"))
        else:
            quality["works_without_usable_primary_source_id"] += 1

        primary_topic_id = openalex_id((work.get("primary_topic") or {}).get("id"))
        topic_objects = list(work.get("topics") or [])
        if primary_topic_id and all(openalex_id(item.get("id")) != primary_topic_id for item in topic_objects):
            topic_objects.append(work.get("primary_topic") or {})
        for topic in topic_objects:
            topic_id, row = topic_row(topic)
            if not topic_id:
                quality["topic_assignments_discarded_missing_topic_id"] += 1
                continue
            if topic_id not in topics:
                topics[topic_id] = row
            else:
                merge_nonempty(topics[topic_id], row)
            work_topics.add((work_id, topic_id, float_csv(topic.get("score")), bool_csv(topic_id == primary_topic_id)))

        for reference in work.get("referenced_works") or []:
            cited_work_id = openalex_id(reference)
            if not cited_work_id or cited_work_id not in selected_ids:
                quality["external_or_invalid_references_not_loaded"] += 1
                continue
            if cited_work_id == work_id:
                quality["citation_self_loops_removed"] += 1
                continue
            citations.add((work_id, cited_work_id))

    work_ids = {row["work_id"] for row in works}
    author_ids = set(authors)
    institution_ids = set(institutions)
    topic_ids = set(topics)
    source_ids = set(sources)
    errors: list[str] = []
    if work_ids != selected_ids:
        errors.append("works.csv IDs differ from selected IDs")
    if any(w not in work_ids or a not in author_ids for w, a, *_ in authorships):
        errors.append("orphan authorship endpoint")
    if any(w not in work_ids or a not in author_ids or i not in institution_ids for w, a, i in affiliations):
        errors.append("orphan affiliation endpoint")
    if any(w not in work_ids or t not in topic_ids for w, t, *_ in work_topics):
        errors.append("orphan work-topic endpoint")
    if any(w not in work_ids or s not in source_ids for w, s, _ in work_sources):
        errors.append("orphan work-source endpoint")
    if any(citing not in work_ids or cited not in work_ids or citing == cited for citing, cited in citations):
        errors.append("invalid citation endpoint")
    if errors:
        raise ValueError("; ".join(errors))

    output_rows: dict[str, tuple[list[str], list[dict[str, str]]]] = {
        "works.csv": (WORK_COLUMNS, sorted(works, key=lambda row: row["work_id"])),
        "authors.csv": (ENTITY_COLUMNS["authors.csv"], [authors[key] for key in sorted(authors)]),
        "institutions.csv": (ENTITY_COLUMNS["institutions.csv"], [institutions[key] for key in sorted(institutions)]),
        "sources.csv": (ENTITY_COLUMNS["sources.csv"], [sources[key] for key in sorted(sources)]),
        "topics.csv": (ENTITY_COLUMNS["topics.csv"], [topics[key] for key in sorted(topics)]),
        "authorships.csv": (RELATION_COLUMNS["authorships.csv"], [dict(zip(RELATION_COLUMNS["authorships.csv"], row)) for row in sorted(authorships)]),
        "affiliations.csv": (RELATION_COLUMNS["affiliations.csv"], [dict(zip(RELATION_COLUMNS["affiliations.csv"], row)) for row in sorted(affiliations)]),
        "work_topics.csv": (RELATION_COLUMNS["work_topics.csv"], [dict(zip(RELATION_COLUMNS["work_topics.csv"], row)) for row in sorted(work_topics)]),
        "work_sources.csv": (RELATION_COLUMNS["work_sources.csv"], [dict(zip(RELATION_COLUMNS["work_sources.csv"], row)) for row in sorted(work_sources)]),
        "citations.csv": (RELATION_COLUMNS["citations.csv"], [dict(zip(RELATION_COLUMNS["citations.csv"], row)) for row in sorted(citations)]),
    }

    null_rates: dict[str, dict[str, float]] = {}
    for filename, (columns, rows) in output_rows.items():
        null_rates[filename] = {
            column: round(sum(not row.get(column, "") for row in rows) / len(rows), 6) if rows else 0.0
            for column in columns
        }

    temp_dir = Path(mkdtemp(prefix="openalex-etl-", dir=processed_dir.parent))
    try:
        for filename, (columns, rows) in output_rows.items():
            write_csv(temp_dir / filename, columns, rows)
        report = {
            "etl_version": "1.0",
            "run_id": manifest.get("run_id", run_dir.name),
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "input": {
                "run_dir": str(run_dir),
                "raw_pages_read": raw_pages_read,
                "raw_work_records_read": raw_work_records,
                "selected_work_count_from_manifest": len(selected_ids),
                "scope_manifest_sha256": sha256_file(manifest_path),
                "selected_work_ids_sha256": manifest.get("selected_work_ids_sha256"),
            },
            "output_row_counts": {filename: len(rows) for filename, (_, rows) in output_rows.items()},
            "discarded_or_normalized_records": dict(sorted(quality.items())),
            "null_rates": null_rates,
            "validation": {
                "passed": True,
                "works_unique": len(work_ids) == len(works),
                "all_relationship_endpoints_valid": True,
                "citation_self_loops": 0,
                "citation_duplicate_directed_pairs": 0,
            },
        }
        (temp_dir / "etl_quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        processed_dir.mkdir(parents=True, exist_ok=True)
        for path in temp_dir.iterdir():
            shutil.move(str(path), processed_dir / path.name)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Create reconciled OpenAlex CSV files from one raw run.")
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--processed-dir", default=Path("data/processed"), type=Path)
    args = parser.parse_args()
    try:
        report = transform(args.run_dir, args.processed_dir)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ETL failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(json.dumps({"validation": report["validation"], "output_row_counts": report["output_row_counts"]}, indent=2))


if __name__ == "__main__":
    main()
