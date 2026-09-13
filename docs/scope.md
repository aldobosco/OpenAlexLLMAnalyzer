## 1. Dataset scope

### Topic area

The project will study **research on large language models (LLMs) and generative AI**, with an emphasis on scientific production, collaboration, venues, topics, and **within-scope citation networks**.

This is a suitable scope because it has a clear research identity, a recent time evolution, multiple entity types (works, authors, institutions, sources, and OpenAlex topics), and non-trivial citation/co-authorship structures. It supports genuinely different relational, graph, and OLAP analyses rather than a graph with only one node or edge type.

### Publication window

- **Inclusive date range:** 1 January 2020 to 31 December 2025.


### Eligible works

A work is eligible when all of the following apply:

1. `publication_date` is in the approved date range.
2. `type` is one of: `article`, `review`, or `preprint`.
3. It is retrieved by at least one fixed LLM/Generative-AI search seed:
   - `large language model`
   - `generative AI`
   - `foundation model`
   - `transformer language model`
4. Its title or available abstract contains at least one case-insensitive validation expression: `large language model`, `LLM`, `generative AI`, `foundation model`, `GPT`, `transformer language model`, or `language model`.
5. It has a non-null OpenAlex work ID and title.

The extractor will request and retain OpenAlex topic assignments. Topic values are not used as the sole inclusion mechanism, because a narrow LLM corpus can be split across several automatically assigned OpenAlex topics. They are instead preserved for topic-level comparisons and OLAP analysis. The implementation must use OpenAlex **Topics**, not the legacy Concepts taxonomy.

### Explicit exclusions

- Works outside the date range.
- Types other than article, review, and preprint (including books, editorials, datasets, corrections, and reference entries).
- Search hits that fail the title/abstract validation rule.
- Duplicate OpenAlex work IDs (one canonical record is retained).
- Relationships with a missing or unresolved endpoint after reconciliation.

## 2. Target size and caps

The goal is a medium-sized local dataset: large enough for meaningful joins and multi-hop traversals, but small enough for repeatable extraction, loading, testing, and benchmarks on a student laptop.

| Object | Target / hard cap | Selection rule |
|---|---:|---|
| Eligible works | 4,800 / 5,000 | At most 800 per publication year; select deterministically by descending `cited_by_count`, then ascending OpenAlex ID after deduplication |
| Authors | Expected 8,000–15,000 / 18,000 | Retain every distinct author attached to retained works; if cap is reached, reduce the work cap and rebuild rather than silently drop authors |
| Institutions | Expected 1,000–4,000 / 5,000 | Retain every distinct institution occurring in retained authorships |
| Sources | No artificial cap | Retain every source of a retained work |
| OpenAlex topics | No artificial cap; normally <=250 | Retain all topic assignments of retained works, including score and primary-topic flag |
| Authorships | No artificial cap | Retain all authorships of retained works, with author position and corresponding-author status where supplied |
| Affiliations | No artificial cap | Retain all author–institution links present in retained authorships |
| Citations | 10,000–25,000 / 30,000 | Retain all valid internal citations; if above cap, apply the deterministic citation rule below |

The target is not accepted merely by reaching counts. Profiling must confirm that the final data contain multiple sources, topics, institutions, multi-author works, and a non-trivial connected/citation component. If internal citations are below 10,000 or the largest weakly connected citation component is below 30% of retained works, increase the per-year work limit (up to the 5,000 hard cap) before proceeding.

## 3. Citation rule

The canonical citation relationship is directed:

`(citing Work) -[:CITES]-> (cited Work)`.

- Keep a citation **only if both citing and cited works are in the final retained-work set**.
- Citation edges whose cited endpoint is outside scope are counted in extraction/profiling metadata but are not loaded into the reconciled, relational, graph, or warehouse models.
- If internal citations exceed 30,000, retain edges ranked by: citing-work publication year descending, cited work's `cited_by_count` descending, then citing ID and cited ID ascending, until the cap. Record both the pre-cap and retained counts.
- Self-citations at work level and duplicate directed pairs are removed. Author self-citation is not removed, because it is a legitimate scholarly property and may be analysed separately later.


## 4. Canonical data model scope

The reconciled layer will include these entities:

- **Work:** OpenAlex ID, DOI, title, publication date/year, type, language where available, cited-by count, open-access status, and selected source metadata.
- **Author:** OpenAlex ID and display name.
- **Institution:** OpenAlex ID, display name, country code, and institution type where available.
- **Source:** OpenAlex ID, display name, source type, ISSN/ISSN-L where available, and publisher where available.
- **Topic:** OpenAlex topic ID, display name, and its domain → field → subfield hierarchy.

It will include these relationships:

- Work–Author authorship, including author position and corresponding-author flag.
- Author–Institution affiliation as represented in an authorship.
- Work–Source publication.
- Work–Topic assignment, including topic score and primary-topic flag.
- Work–Work internal citation.

The final graph therefore uses labels `Work`, `Author`, `Institution`, `Source`, and `Topic`, and relationship types `AUTHORED`, `AFFILIATED_WITH`, `PUBLISHED_IN`, `HAS_TOPIC`, and `CITES`.

## 5. Analytical questions

| ID | Question | Primary orientation | Why it drives the design |
|---|---|---|---|
| Q1 | How did the number of LLM/Generative-AI works and their median/average citations evolve by year, work type, and source? | O | Requires time, source, and publication measures with roll-up/drill-down |
| Q2 | Which authors, institutions, and sources are most productive or most cited, and how do rankings change by year and topic? | R/O | Requires precise joins, grouping, ranking, and dimensional slicing |
| Q3 | Which topic subfields and sources have the highest growth in publications and citation impact from 2020 to 2025? | O | Uses the Topic hierarchy and Time hierarchy in an OLAP session |
| Q4 | Which author–institution collaborations produce the most works and the highest citation impact, by year? | R | Tests many-to-many authorship/affiliation joins and aggregate correctness |
| Q5 | Which LLM works are connected by citation paths of length 2–4, and what are the shortest paths between selected highly cited works? | G | Tests directed variable-length traversals that are naturally expressed in Cypher |
| Q6 | Which authors act as bridges between otherwise weakly connected co-authorship communities, and which institutions do they connect? | G | Uses projected co-author paths, community/centrality analysis, and affiliations |

Q2 and Q4 will be part of the shared SQL/Cypher comparison suite only where identical semantics can be guaranteed. Q1 and Q3 are warehouse-led questions; Q5–Q6 are graph-led questions. At least 4–6 questions spanning aggregation, multi-table joins, collaboration, citations, and time/topic analysis will be implemented with equivalent SQL and Cypher versions where applicable.

## 6. Warehouse design commitments

The business process is scholarly publication and collaboration analysis. The initial DFM will be created before physical implementation.

- **Primary fact grain:** one retained work at its publication level, with additive publication count and citation-count measures.
- **Bridge/fact support:** a work-authorship bridge/fact and a work-topic bridge/fact will preserve many-to-many relationships without double-counting; documented allocation rules will be used for any author/topic-level aggregate.
- **Dimensions and hierarchies:**
  - `DimTime`: day → month → quarter → year.
  - `DimTopic`: topic → subfield → field → domain.
  - `DimSource`: source → publisher (when available) → source type.
  - `DimInstitution`: institution → country → institution type.
  - `DimWorkType`: work type.
- **Physical choice:** begin with a star schema, retaining denormalized hierarchy attributes in dimensions. This is preferable for transparent OLAP SQL and a compact local dataset. A snowflake will be adopted only if profiling shows that repeated hierarchy attributes make dimension maintenance materially problematic.

## 7. Evaluation plan

### Correctness

- Reconcile entity and relationship counts from processed files to PostgreSQL and Neo4j after every load.
- Validate primary-key uniqueness, foreign-key/citation endpoint validity, duplicate directed citations, orphan records, and null rates.
- For each shared SQL/Cypher question, compare the canonicalized result set (same grouping keys, ordering, and numeric measures); investigate every mismatch.
- Validate warehouse publication and citation aggregates against equivalent queries over the reconciled relational layer.

### Expressiveness and readability

For each query, document the number of joins or traversal hops, query length, use of recursion/path syntax, readability of the core pattern, and any special handling required to obtain equivalent semantics. The discussion will distinguish relational strengths in filtering/aggregation from graph strengths in variable-length and multi-relationship traversals.

### Performance

- Run both systems locally through the same processed snapshot, on the same machine, with documented CPU/RAM, DB versions, configuration, indexes, and dataset counts.
- Use a warm-up execution followed by five timed warm-cache repetitions per query; report median, minimum, maximum, and output cardinality.
- Record PostgreSQL `EXPLAIN ANALYZE` and Neo4j `PROFILE`/plan evidence for representative queries.
- Benchmark only semantically equivalent queries; do not compare a graph-native path/centrality operation with an unrelated simple SQL aggregation.

### Modeling and implementation complexity

Compare the number of entity/relationship or table constructs, keys/constraints/indexes, ETL transformations, loading steps, and query-specific workarounds. Assess data integrity, maintainability, and how directly each model represents authorship, affiliation, topics, and citations.

## 8. Reproducibility and extraction settings

- Use the OpenAlex Works API with fixed search seeds, fixed date/type filters, cursor pagination, explicit field selection, and a polite-pool email/API key where available.
- Store the exact request parameters, retrieval timestamp, API/base URL, cursor/page state, raw response file names, API version/metadata when exposed, and count at every extraction stage.
- Store raw API responses unchanged under `data/raw/`; write flattened, validated outputs only under `data/processed/`.
- Save a scope manifest containing the seed phrases, validation regex, resolved topic metadata, selection ordering, work limit, citation cap, and final ID lists/checksums.
- Never use an unseeded random sample. The selected population must be deterministic from the recorded extraction result and rules.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Keyword search includes non-LLM uses of “GPT” or “language model” | Require a fixed seed plus title/abstract validation; profile and manually inspect a stratified sample before freezing data |
| Abstracts or affiliation data are missing | Do not fabricate values; retain nulls, measure coverage, and qualify analyses that depend on missing fields |
| API metadata changes over time | Freeze raw responses and a scope manifest; analyze only the frozen snapshot |
| Citation graph is sparse after the closed-network rule | Profile component size and internal-edge count; increase the deterministic work limit within the hard cap before finalizing |
| Citations favour older works | Always report publication year and use year-normalized citation measures where needed |

