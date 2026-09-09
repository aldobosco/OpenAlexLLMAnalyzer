"""
Examples:
  python scripts/extract/openalex_milestone2.py extract
  python scripts/extract/openalex_milestone2.py profile --run-id 20260825T170000Z

Set OPENALEX_API_KEY in .env or in the shell. This program never writes the key.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import requests
from dotenv import load_dotenv

BASE_URL = "https://api.openalex.org/works"
START_YEAR, END_YEAR = 2020, 2025
SEEDS = [
    "large language model",
    "generative AI",
    "foundation model",
    "transformer language model",
]
ALLOWED_TYPES = "article|review|preprint"
MAX_PER_YEAR = 800
PER_PAGE = 100
VALIDATION_RE = re.compile(
    r"large language model|\bllms?\b|generative ai|foundation model|\bgpt\b|"
    r"transformer language model|language model",
    re.IGNORECASE,
)
SELECT_FIELDS = ",".join(
    [
        "id", "doi", "title", "publication_date", "publication_year", "type",
        "language", "cited_by_count", "open_access", "abstract_inverted_index",
        "authorships", "primary_location", "topics", "primary_topic", "referenced_works",
    ]
)


def openalex_id(value: str | None) -> str | None:
    if not value:
        return None
    return value.rstrip("/").rsplit("/", 1)[-1]


def reconstruct_abstract(index: dict[str, list[int]] | None) -> str:
    if not index:
        return ""
    positions: dict[int, str] = {}
    for token, indexes in index.items():
        for position in indexes:
            positions[position] = token
    return " ".join(positions[position] for position in sorted(positions))


def canonical_json_sha256(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def request_json(session: requests.Session, params: dict[str, str]) -> dict[str, Any]:
    for attempt in range(6):
        response = session.get(BASE_URL, params=params, timeout=60)
        if response.status_code == 200:
            return response.json()
        if response.status_code in {429, 500, 502, 503, 504}:
            time.sleep(min(60, 2**attempt))
            continue
        response.raise_for_status()
    raise RuntimeError("OpenAlex request failed after six attempts")


def extract(root: Path) -> None:
    load_dotenv()
    api_key = os.getenv("OPENALEX_API_KEY")
    if not api_key:
        raise SystemExit("OPENALEX_API_KEY is missing. Put it in .env; do not commit .env.")

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = root / "data" / "raw" / "openalex" / run_id
    response_dir = run_dir / "responses"
    response_dir.mkdir(parents=True, exist_ok=False)
    metadata: dict[str, Any] = {
        "run_id": run_id,
        "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
        "api_base_url": BASE_URL,
        "corpus": "core",
        "scope": {
            "years": [START_YEAR, END_YEAR],
            "types": ALLOWED_TYPES.split("|"),
            "seeds": SEEDS,
            "per_year_cap_after_validation_and_deduplication": MAX_PER_YEAR,
            "validation_regex": VALIDATION_RE.pattern,
            "selected_fields": SELECT_FIELDS.split(","),
        },
        "requests": [],
        "response_files": [],
    }

    with requests.Session() as session:
        session.headers["User-Agent"] = "OpenAlexLLMAnalizer/0.1 (student database project)"
        for year in range(START_YEAR, END_YEAR + 1):
            for seed_number, seed in enumerate(SEEDS, start=1):
                cursor = "*"
                page_number = 0
                while cursor:
                    page_number += 1
                    params = {
                        "search": seed,
                        "filter": f"from_publication_date:{year}-01-01,to_publication_date:{year}-12-31,type:{ALLOWED_TYPES}",
                        "select": SELECT_FIELDS,
                        "sort": "cited_by_count:desc",
                        "per_page": str(PER_PAGE),
                        "cursor": cursor,
                        "corpus": "core",
                        "api_key": api_key,
                    }
                    response_data = request_json(session, params)
                    filename = f"year_{year}__seed_{seed_number:02d}__page_{page_number:04d}.json"
                    output_path = response_dir / filename
                    output_path.write_text(json.dumps(response_data, ensure_ascii=False, indent=2), encoding="utf-8")
                    safe_params = {key: value for key, value in params.items() if key != "api_key"}
                    metadata["requests"].append(
                        {
                            "year": year,
                            "seed": seed,
                            "page": page_number,
                            "parameters": safe_params,
                            "meta": response_data.get("meta", {}),
                            "file": str(Path("responses") / filename),
                        }
                    )
                    metadata["response_files"].append(filename)
                    results = response_data.get("results", [])
                    cursor = response_data.get("meta", {}).get("next_cursor")
                    if not results or not cursor:
                        break
                    time.sleep(0.15)

    metadata["completed_at_utc"] = datetime.now(timezone.utc).isoformat()
    (run_dir / "extraction_metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Raw OpenAlex responses written to {run_dir}")
    print(f"Next: python {Path(__file__).as_posix()} profile --run-id {run_id}")


def update_profile(
    work: dict[str, Any],
    state: dict[str, Any],
    start_year: int = START_YEAR,
    end_year: int = END_YEAR,
) -> None:
    work_id = openalex_id(work.get("id"))
    if not work_id:
        return

    title = (work.get("title") or "").strip()
    year = work.get("publication_year")
    if not title:
        state["exclusion_reasons"]["missing_title"] += 1
        state["missing"]["title"] += 1
        return
    if not (start_year <= (year or -1) <= end_year):
        state["exclusion_reasons"]["outside_year_range"] += 1
        return
    if work.get("type") not in ALLOWED_TYPES.split("|"):
        state["exclusion_reasons"]["excluded_type"] += 1
        return

    abstract = reconstruct_abstract(work.get("abstract_inverted_index"))
    if not VALIDATION_RE.search(f"{title}\n{abstract}"):
        state["exclusion_reasons"]["failed_title_abstract_validation"] += 1
        return

    state["validated_candidate_count"] += 1
    state["years"][str(year)] += 1
    if not abstract:
        state["missing"]["abstract"] += 1
    if not work.get("doi"):
        state["missing"]["doi"] += 1
    if not work.get("publication_date"):
        state["missing"]["publication_date"] += 1

    authorships = work.get("authorships") or []
    state["author_counts"].append(len(authorships))
    for authorship in authorships:
        author_id = openalex_id((authorship.get("author") or {}).get("id"))
        if author_id:
            state["author_ids"].add(author_id)
        else:
            state["missing"]["author_id"] += 1
        for institution in authorship.get("institutions") or []:
            institution_id = openalex_id(institution.get("id"))
            if institution_id:
                state["institution_ids"].add(institution_id)
                state["affiliation_count"] += 1

    source_id = openalex_id((((work.get("primary_location") or {}).get("source") or {}).get("id")))
    if source_id:
        state["source_ids"].add(source_id)
    else:
        state["missing"]["primary_source_id"] += 1

    for topic in work.get("topics") or []:
        topic_id = openalex_id(topic.get("id"))
        if topic_id:
            state["topic_ids"].add(topic_id)
            state["topic_count"] += 1

    references = work.get("referenced_works") or []
    if references:
        state["works_with_references"] += 1
        state["external_reference_count"] += len(references)

    cited_by = work.get("cited_by_count") or 0
    clean_refs = [openalex_id(ref) for ref in references if openalex_id(ref)]
    state["candidate_works"].setdefault(year, []).append((cited_by, work_id, clean_refs))


def load_unique_works(
    run_dir: Path,
    on_work: Callable[[dict[str, Any]], None] | None = None,
) -> tuple[set[str], int]:
    seen_ids: set[str] = set()
    duplicate_occurrences = 0
    for page_path in sorted((run_dir / "responses").glob("*.json")):
        page = json.loads(page_path.read_text(encoding="utf-8"))
        for work in page.get("results", []) or []:
            work_id = openalex_id(work.get("id"))
            if not work_id:
                continue
            if work_id in seen_ids:
                duplicate_occurrences += 1
                continue
            seen_ids.add(work_id)
            if on_work is not None:
                on_work(work)
    return seen_ids, duplicate_occurrences


def profile(
    root: Path,
    run_id: str,
    start_year: int = START_YEAR,
    end_year: int = END_YEAR,
) -> None:
    run_dir = root / "data" / "raw" / "openalex" / run_id
    if not run_dir.exists():
        raise SystemExit(f"No raw extraction directory exists at {run_dir}")

    state: dict[str, Any] = {
        "validated_candidate_count": 0,
        "exclusion_reasons": Counter(),
        "years": Counter(),
        "author_counts": [],
        "topic_count": 0,
        "affiliation_count": 0,
        "works_with_references": 0,
        "external_reference_count": 0,
        "author_ids": set(),
        "institution_ids": set(),
        "source_ids": set(),
        "topic_ids": set(),
        "missing": Counter(),
        "candidate_works": {},
    }

    seen_ids, duplicate_occurrences = load_unique_works(
        run_dir,
        on_work=lambda work: update_profile(work, state, start_year=start_year, end_year=end_year),
    )

    selected_by_year: dict[str, list[str]] = {}
    retained_ids: set[str] = set()
    retained_references: dict[str, list[str]] = {}
    for year in range(start_year, end_year + 1):
        year_candidates = state["candidate_works"].get(year, [])
        year_candidates.sort(key=lambda item: (-item[0], item[1]))
        selected = year_candidates[:MAX_PER_YEAR]
        selected_ids = [item[1] for item in selected]
        selected_by_year[str(year)] = selected_ids
        retained_ids.update(selected_ids)
        for item in selected:
            retained_references[item[1]] = item[2]

    internal_edges = {
        (work_id, ref)
        for work_id, refs in retained_references.items()
        for ref in refs
        if ref in retained_ids and ref != work_id
    }
    selected_counts = {year: len(ids) for year, ids in selected_by_year.items()}
    profile_data = {
        "run_id": run_id,
        "profiled_at_utc": datetime.now(timezone.utc).isoformat(),
        "raw_unique_work_count": len(seen_ids),
        "duplicate_work_occurrences_across_seed_queries": duplicate_occurrences,
        "validated_candidate_work_count": state["validated_candidate_count"],
        "exclusion_reasons": dict(state["exclusion_reasons"]),
        "candidate_year_distribution": dict(sorted(state["years"].items())),
        "missing_field_counts_in_validated_candidates": dict(state["missing"]),
        "author_count_per_work": {
            "min": min(state["author_counts"], default=0),
            "max": max(state["author_counts"], default=0),
            "mean": round(sum(state["author_counts"]) / len(state["author_counts"]), 3) if state["author_counts"] else 0,
        },
        "distinct_entities_in_validated_candidates": {
            "authors": len(state["author_ids"]),
            "institutions": len(state["institution_ids"]),
            "sources": len(state["source_ids"]),
            "topics": len(state["topic_ids"]),
        },
        "coverage": {
            "works_with_at_least_one_reference": state["works_with_references"],
            "reference_list_entries": state["external_reference_count"],
            "topic_assignments": state["topic_count"],
            "affiliation_links": state["affiliation_count"],
        },
        "deterministic_selection": {
            "rule": "Within each publication year, validated works sorted by cited_by_count descending then OpenAlex ID ascending; retain first 800.",
            "selected_work_count": len(retained_ids),
            "selected_counts_by_year": selected_counts,
            "selected_work_ids_by_year": selected_by_year,
            "selected_work_ids_sha256": canonical_json_sha256(selected_by_year),
        },
        "within_scope_citations": {
            "rule": "Directed citing_work -> cited_work; both endpoints selected; self-loops and duplicate pairs removed.",
            "unique_internal_edge_count": len(internal_edges),
        },
        "milestone_2_gate": {
            "work_cap_satisfied": len(retained_ids) <= 5000,
            "citation_target_minimum_met": len(internal_edges) >= 10000,
            "citation_hard_cap_exceeded": len(internal_edges) > 30000,
            "notes": "Compute the largest weakly connected component in Milestone 3 before declaring citation-network adequacy.",
        },
    }
    (run_dir / "raw_profile.json").write_text(json.dumps(profile_data, ensure_ascii=False, indent=2), encoding="utf-8")
    (run_dir / "scope_manifest.json").write_text(
        json.dumps(profile_data["deterministic_selection"], ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(profile_data["milestone_2_gate"], indent=2))
    print(f"Profile and deterministic scope manifest written to {run_dir}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["extract", "profile"])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--run-id")
    parser.add_argument("--start-year", type=int, default=START_YEAR)
    parser.add_argument("--end-year", type=int, default=END_YEAR)
    args = parser.parse_args()
    if args.command == "extract":
        extract(args.root)
    else:
        if not args.run_id:
            parser.error("profile requires --run-id")
        profile(args.root, args.run_id, start_year=args.start_year, end_year=args.end_year)


if __name__ == "__main__":
    main()
