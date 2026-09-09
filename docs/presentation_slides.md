---
marp: true
theme: default
paginate: true
header: "OpenAlex LLM Analyzer — Relational, Graph & Warehouse Architecture"
footer: "PostgreSQL · Neo4j · Data Warehouse (DFM)"
style: |
  section {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    color: #1e293b;
    background-color: #f8fafc;
  }
  h1 { color: #0f172a; }
  h2 { color: #1e40af; }
  h3 { color: #3b82f6; }
  table { font-size: 0.85em; }
  code { background-color: #e2e8f0; color: #0f172a; border-radius: 4px; padding: 2px 6px; }
  pre code { background-color: #0f172a; color: #f8fafc; }
---

# OpenAlex LLM Analyzer
## Comparative Scholarly Analytics Across Relational, Graph & Data Warehouse Paradigms

**Topic:** Scientific Production & Citation Networks in LLM & Generative AI Research (2020–2025)  
**Technologies:** PostgreSQL 16 (Relational OLTP & Star Schema) · Neo4j 5 (Labeled Property Graph) · Python 3.11+ ETL

---

## 1. Project Goal & Motivation

### Core Research Objective
Build a **fully reproducible, multi-paradigm database evaluation system** that extracts scholarly literature from OpenAlex and loads identical datasets into:
1. **Relational Database (PostgreSQL OLTP - 3NF):** Entity integrity & tabular joins.
2. **Graph Database (Neo4j LPG):** Native index-free citation & co-authorship traversals.
3. **Data Warehouse (PostgreSQL Star Schema - DFM):** Dimensional roll-up, drill-down & OLAP slicing.

### Domain Focus: LLMs & Generative AI (2020–2025)
- Fast-evolving scholarly domain with massive preprint volume (arXiv) and high collaboration.
- Non-trivial heterogeneous networks: multi-authored papers, institutional affiliations, cross-domain topic hierarchies, and directed citation cascades.

---

## 2. Target Scope & Boundary Rules

### Inclusion & Capping Rules
- **Publication Window:** 1 January 2020 to 31 December 2025.
- **Work Types:** `article`, `review`, `preprint` (excluding books, editorials, corrections).
- **Search Seeds:** `"large language model"`, `"generative AI"`, `"foundation model"`, `"transformer language model"`.
- **Validation Expression:** Regular expression validation against title/abstract.
- **Deterministic Hard Caps:** Max 800 works/year (~4,800 total cap), selected by `cited_by_count DESC, id ASC`.

### Analytical Questions
- **Q1 (OLAP):** Production evolution, average & median citations by year and work type.
- **Q2 (Relational/OLAP):** Productivity & impact rankings for authors, institutions, and sources.
- **Q3 (OLAP):** Topic subfield growth across the OpenAlex domain hierarchy.
- **Q4 (Relational):** Inter-institutional collaborative partnerships by publication year.
- **Q5–Q7 (Graph):** Multi-hop citation chains (2–4 hops), co-author degree bridges, and contextual recommendations.

---

## 3. End-to-End System Architecture

```
                       [ OpenAlex REST API ]
                                | (Cursor Pagination, Seeds, Polite Pool)
                                v
                   [ data/raw/openalex/<run_id>/ ]
                     - Immutable JSON pages
                     - Scope manifest + SHA-256 hashes
                                |
                                v
                 [ Python ETL: scripts/transform/run_etl.py ]
                     - Abstract inverted index reconstruction
                     - Closed-network citation pruning
                     - Discarding dangling references & self-loops
                                |
                                v
                     [ data/processed/*.csv ]
                     (10 Reconciled Normalized CSVs)
                   /            |             \
                  v             v              v
         [ PostgreSQL OLTP ] [ Neo4j LPG ] [ Data Warehouse ]
           Schema: openalex    Labels &      Schema: warehouse
             (3NF Tables)     Properties       (Star Schema)
```

---

## 4. Normalized Data Layer (10 Reconciled Contracts)

The dataset is frozen into 10 canonical CSV files loaded identically across all backends:

| Category | File / Relation | Natural / Primary Key | Key Attributes |
|---|---|---|---|
| **Entities** | `works.csv` | `work_id` | `doi`, `title`, `abstract`, `publication_date`, `year`, `work_type`, `citations` |
| | `authors.csv` | `author_id` | `display_name` |
| | `institutions.csv` | `institution_id` | `display_name`, `country_code`, `institution_type` |
| | `sources.csv` | `source_id` | `display_name`, `source_type`, `issn`, `publisher` |
| | `topics.csv` | `topic_id` | `display_name`, `subfield_name`, `field_name`, `domain_name` |
| **Relations** | `authorships.csv` | `(work_id, author_id)` | `author_position`, `author_order`, `is_corresponding` |
| | `affiliations.csv` | `(work_id, author_id, inst_id)` | Contextual institutional affiliation per paper |
| | `work_topics.csv` | `(work_id, topic_id)` | `score`, `is_primary_topic` |
| | `work_sources.csv` | `(work_id, source_id)` | `location_role` (primary location host) |
| | `citations.csv` | `(citing_id, cited_id)` | Directed within-scope edge |

---

## 5. Critical Implementation Point 1: Closed-Network Citation Integrity

### The Challenge
- Real-world bibliometrics cite works outside any sampled boundary.
- An open citation list produces **dangling pointers**, violating relational Foreign Keys and breaking graph reachability traversals.

### The Solution
- Enforce a **strict closed-network boundary rule**:
  $$\text{Edges retained} = \{ (u, v) \in \text{Citations} \mid u \in \text{Works}_{\text{retained}} \land v \in \text{Works}_{\text{retained}} \land u \ne v \}$$
- Self-citations at work level ($u = u$) are stripped.
- In the pilot dataset: **8,850 external references were pruned**, keeping 111–240 valid internal citation edges with **0 foreign key violations** and **0 phantom graph nodes**.

---

## 6. Critical Implementation Point 2: Work-Contextual Affiliations

### The Fallacy of Static Affiliations
- In reality, researcher affiliations change over time and vary across projects.
- Modeling a direct edge `(:Author)-[:AFFILIATED_WITH]->(:Institution)` falsely asserts an author always belonged to that institution for all works.

### Dual-Paradigm Implementation
- **Relational:** Ternary association table `affiliations(work_id, author_id, institution_id)` with a compound foreign key referencing `authorships(work_id, author_id)`.
- **Graph:** Neo4j stores `work_id` directly on the relationship:
  `(:Author)-[:AFFILIATED_WITH {work_id: "W..."}]->(:Institution)`
- **Query Pattern:** Guarantees work-scoped traversal semantics:
  ```cypher
  MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
  MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
  ```

---

## 7. Implementation: Relational OLTP (PostgreSQL)

### Model Characteristics
- Third Normal Form (3NF) relational design in PostgreSQL 16 (`openalex` schema).
- Cascading referential integrity constraints, check constraints (`cited_by_count >= 0`), composite primary keys.
- Targeted B-Tree indexes on join and filter columns:
  - `idx_works_year_type`, `idx_authorships_author`, `idx_affiliations_inst`, `idx_citations_cited`.

### Loading & Validation
- Loaded via high-performance streaming `COPY FROM STDIN WITH (FORMAT CSV)`.
- Automated validation queries verify row parity, lack of orphans, and foreign key consistency.

---

## 8. Implementation: Graph Database (Neo4j)

### Labeled Property Graph (LPG)
- **Nodes:** `(:Work)`, `(:Author)`, `(:Institution)`, `(:Source)`, `(:Topic)`.
- **Edges:**
  - `(:Author)-[:AUTHORED {author_position, is_corresponding}]->(:Work)`
  - `(:Author)-[:AFFILIATED_WITH {work_id}]->(:Institution)`
  - `(:Work)-[:HAS_TOPIC {score, is_primary_topic}]->(:Topic)`
  - `(:Work)-[:PUBLISHED_IN]->(:Source)`
  - `(:Work)-[:CITES]->(:Work)`

### Constraints & Indexes
- Range uniqueness constraints on `(node.id)`.
- High-throughput batch loading with `UNWIND $rows AS row ... MERGE` transactions (1,000 items/batch).

---

## 9. Implementation: Analytical Data Warehouse (Star Schema)

### Dimensional Fact Model (DFM)
- **Fact Table:** `fact_work`
  - Grain: One row per retained work.
  - Measures: `publication_count = 1` (fully additive), `cited_by_count` (semi-additive snapshot).
  - Degenerate Dimension: `publication_year` (retains reporting ability even if full date is unknown).
- **Conformed Dimensions:** `dim_date`, `dim_source`, `dim_work_type`, `dim_author`, `dim_institution`, `dim_topic`.

### Multi-Valued Bridge Strategy
- Solves many-to-many author and topic assignments via bridge tables:
  - `bridge_work_author`, `bridge_work_topic`, `bridge_work_institution`.
- **Full Association Accounting:** Works multi-assigned to $k$ topics contribute fully to each topic's association-level aggregate. Corpus-wide totals use `fact_work` alone.

---

## 10. Query Expressiveness: SQL vs. Cypher

### Question 5: Variable-Length Citation Paths (2 to 4 Hops)

#### PostgreSQL Recursive CTE (25 lines)
```sql
WITH RECURSIVE citation_paths AS (
  SELECT c.citing_work_id, c.cited_work_id, ARRAY[c.citing_work_id, c.cited_work_id]::TEXT[] AS path, 1 AS hops
  FROM citations c WHERE c.citing_work_id = :start_id
  UNION ALL
  SELECT p.citing_work_id, c.cited_work_id, p.path || c.cited_work_id, p.hops + 1
  FROM citation_paths p JOIN citations c ON c.citing_work_id = p.cited_work_id
  WHERE p.hops < 4 AND NOT c.cited_work_id = ANY (p.path)
)
SELECT * FROM citation_paths WHERE hops BETWEEN 2 AND 4;
```

#### Neo4j Cypher Native Traversal (3 lines)
```cypher
MATCH p = (start:Work {id: $start_id})-[:CITES*2..4]->(target:Work)
RETURN length(p) AS hops, [n IN nodes(p) | n.id] AS path;
```
**Takeaway:** Cypher expresses topological path traversal concisely with built-in uniqueness and pointer-chasing; SQL requires recursive CTEs, manual array cycle tracking, and expensive self-joins.

---

## 11. Performance Analysis & Execution Plans

### Relational Execution (`EXPLAIN ANALYZE, BUFFERS`)
- **Top Authors (Q2A):** Hash Join `authors` $\to$ HashAggregate on `(work_id, author_id)` $\to$ Sort.
  - Execution time: **5.67 ms** (warm cache, pilot data).
- **Institutional Pairs (Q4):** Nested Loop / Hash Join of self-joined affiliations with subquery distinct filtering.

### Warehouse vs. 3NF Relational Timing
- **Star Schema Aggregations:** Slicing by `dim_work_type` or `publication_year` directly on `fact_work` avoids 3NF multi-table join paths, scanning compact sequential blocks.
- **Bridge Queries:** Streamlined integer surrogate keys (`work_key`, `author_key`) accelerate hash joins compared to text string UUID joins in the normalized OLTP schema.

### Graph Profile (`PROFILE`)
- **Index-Free Adjacency:** Directed citations traversed directly in memory via double-linked pointer chains without index lookups after starting node identification.

---

## 12. Explicit Final Results: Domain Insights

### 1. The Preprint Dominance Phenomenon
- In the 2020 foundation model cohort, **preprints outnumbered peer-reviewed articles by >2:1** (435 preprints vs. 203 articles).
- High citation velocity across both: Mean citations of **54.72** (articles) vs. **51.41** (preprints), reflecting arXiv-first research dissemination in generative AI.

### 2. Scholarly Productivity & Impact Leaders
- Top authors in corpus:
  - **Jianfeng Gao:** 11 works, 1,104 citations
  - **Richard Socher:** 10 works, 699 citations
  - **Furu Wei:** 7 works, 1,082 citations
  - **Ming Zhou:** 5 works, 1,113 citations
  - **Yejin Choi:** 7 works, 256 citations

### 3. Citation Path Distribution (G1)
- 2-hop paths: **419** | 3-hop paths: **175** | 4-hop paths: **37**
- Proves clear citation clustering around early seminal transformer architectures.

---

## 13. Paradigm Decision Matrix

| Dimension | PostgreSQL (Relational 3NF) | Neo4j (Graph LPG) | Data Warehouse (Star Schema) |
|---|---|---|---|
| **Best Fit For** | Transactional CRUD, data integrity, strict typing | Deep path discovery, co-authorship, centrality | Slicing/dicing, trend analysis, reporting roll-ups |
| **Schema Flexibility** | Rigid (DDL migrations required) | Dynamic (property additions effortless) | Structured (Dimensional bus architecture) |
| **Join Scalability** | Degrades with join depth ($>3$ tables) | O(1) per step via Index-Free Adjacency | Predictable star joins against Fact table |
| **Path Traversal Syntax** | Verbose (`WITH RECURSIVE`, array loops) | Intuitive ASCII pattern `(a)-[:CITES*]->(b)` | Factless relationship bridge required |
| **Aggregation Power** | Excellent SQL window functions & CTEs | Adequate (`collect()`, `reduce()`), higher RAM | Superior (Vectorized aggregates, columnar-ready) |

---

## 14. Summary & Conclusions

### Project Accomplishments
1. **End-to-End Reproducibility:** Automated pipeline from OpenAlex API to 3 operational database architectures.
2. **Methodological Rigor:** 100% data reconciliation, closed-network edge consistency, and exact semantic alignment between SQL and Cypher queries.
3. **Multi-Paradigm Insights:** Demonstrated empirical proof of where graph engines surpass relational engines (paths/networks) and where dimensional schemas excel (aggregations/slicing).

### Deliverables in Repository
- `scripts/extract/gather.py`: Resilient OpenAlex extractor with cursor pagination.
- `scripts/transform/run_etl.py`: Strict reconciliation & quality validation engine.
- `sql/relational/`: 3NF schema, index suite, analytical SQL, EXPLAIN benchmarks.
- `sql/warehouse/`: DFM star schema, conformed dimensions, bridge tables.
- `cypher/`: Constraints, LPG loads, shared queries, graph-native algorithms.
- `docs/evidence/`: Complete verification transcripts and query execution plans.
