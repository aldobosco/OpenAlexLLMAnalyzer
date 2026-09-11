# Comparative Performance Benchmark: Relational vs. Warehouse vs. Graph

This document details the multi-paradigm performance evaluation suite designed to compare the three database architectures implemented in this repository over the reconciled OpenAlex dataset:

1. **PostgreSQL Relational (OLTP / 3NF)**: `openalex` schema
2. **PostgreSQL Data Warehouse (OLAP / Star Schema)**: `warehouse` schema
3. **Neo4j Graph Database (Labeled Property Graph)**: Cypher engine

---

## 1. Evaluation Workloads

Six semantically equivalent queries were constructed to expose the fundamental performance tradeoffs between tabular relational algebra, dimensional star models, and graph pointer-chasing traversals.

| Workload ID | Analytical Goal | Relational Implementation | Warehouse Implementation | Graph (Cypher) Implementation | Primary Paradigm Winner |
|---|---|---|---|---|---|
| **Q2A** | Top 20 author productivity & citations | 3-table join (`authors` $\to$ `authorships` $\to$ `works`) | Star-join via `bridge_work_author` & `dim_author` | `(a:Author)-[:AUTHORED]->(w:Work)` with `collect()` & `reduce()` | **Relational / Warehouse** |
| **Q2B** | Top 20 institutions with contextual dedup | CTE with `DISTINCT` over `affiliations` | `bridge_work_institution` & `dim_institution` | Contextual traversal matching `af.work_id = w.id` | **Warehouse** |
| **Q3** | Topic-field hierarchical roll-up (year 2020) | Multi-table joins across normalized entities | Fact table predicate pushdown + `dim_topic` | Node property scan + traversal to `:Topic` | **Data Warehouse** |
| **Q4** | Institutional collaboration (diamond join) | Self-join on `affiliations` with `id_2 > id_1` | Self-join on `bridge_work_institution` | Multi-path diamond pattern match | **Relational / Warehouse** |
| **Q5** | Multi-hop directed citation paths (2–4 hops) | `WITH RECURSIVE` + cycle array check | `WITH RECURSIVE` on `bridge_work_citation` | Native traversal `[:CITES*2..4]` | **Graph (by orders of magnitude)** |
| **Q6** | Co-authorship degree (bipartite expansion) | Self-join on `authorships` + `UNION ALL` | Self-join on `bridge_work_author` + `UNION ALL` | `(a1)-[:AUTHORED]->(w)<-[:AUTHORED]-(a2)` | **Graph** |

---

## 2. Architectural Analysis: Why Paradigms Differ

### A. Deep Path Traversals (Workload Q5)
* **The Graph Advantage**: Neo4j uses **Index-Free Adjacency (IFA)**. Each `Work` node holds direct physical pointers to adjacent relationship records. Expanding from hop 1 to hop 4 costs $O(k)$ where $k$ is the degree, without touching a central index.
* **The Relational & Warehouse Bottleneck**: Both PostgreSQL schemas must evaluate a recursive CTE (`WITH RECURSIVE`). For each step, PostgreSQL materializes intermediate worktables, evaluates B-Tree index scans on `citing_work_id`, and executes an array search (`NOT c.cited_work_id = ANY(p.path)`) on every candidate row to prevent cycles. As hops increase from 2 to 4, buffer memory and join overhead explode exponentially.

### B. Dimensional Aggregations & Hierarchical Slicing (Workload Q3)
* **The Warehouse Advantage**: The Star Schema shines on dimensional slicing. In `fact_work`, rows are filtered immediately by `f.publication_year = 2020` without traversing joins. Surrogate integer keys (`work_key`, `topic_key`) allow fast integer hash joins into the denormalized `dim_topic` table containing pre-computed `field_name` attributes.
* **The Graph Bottleneck**: Neo4j does not have a columnar storage layer. To compute the aggregation, it must scan candidate nodes, access property stores to inspect `publication_year`, follow `:HAS_TOPIC` edges to `Topic` nodes, group results in dynamic memory structures, and compute averages without vectorized hardware acceleration.

### C. Large Tabular Aggregations & Groupings (Workload Q2A & Q2B)
* **The Relational & Warehouse Advantage**: PostgreSQL employs mature C-level `HashAggregate` and external disk-backed sort algorithms optimized over decades. Grouping tens of thousands of rows by author ID and computing sums/counts is memory-compact and cache-friendly.
* **The Graph Bottleneck**: In Cypher, calculating aggregated metrics across $M:N$ entities often requires grouping intermediate nodes into in-memory collections (`collect(DISTINCT w)`) and iterating over them using Cypher expression functions (`reduce()`). This incurs Java heap allocation overhead and high database hits.

---

## 3. How to Run the Comparisons

### Method 1: Automated Multi-Paradigm Benchmark
Run the cross-paradigm benchmark script:
```bash
python scripts/evaluation/benchmark_comparison.py --iterations 5
```
To run a specific workload (e.g. Q3 or Q5):
```bash
python scripts/evaluation/benchmark_comparison.py --workload Q5
```
The script performs 1 warm-up run per query, followed by 5 warm-cache iterations, reporting median, min, and max execution times alongside row counts to guarantee semantic equivalence.

### Method 2: Manual Relational vs. Warehouse Profiling (PostgreSQL)
Run [`sql/warehouse/05_compare_relational_timing.sql`](file:///home/tiz/Documents/uni/OpenAlexLLMAnalyzer/sql/warehouse/05_compare_relational_timing.sql) using `psql`:
```bash
psql -h localhost -p 5432 -U openalex_app -d openalex -f sql/warehouse/05_compare_relational_timing.sql
```
Inspect the output lines:
* `Execution Time: X.XX ms`
* `Buffers: shared hit=N, read=M`

### Method 3: Manual Graph Profiling (Neo4j)
Run [`cypher/05_compare_graph_timing.cypher`](file:///home/tiz/Documents/uni/OpenAlexLLMAnalyzer/cypher/05_compare_graph_timing.cypher) in Neo4j Browser (`http://localhost:7474`) or via `cypher-shell`:
```bash
cypher-shell -u neo4j -p openalex_graph -f cypher/05_compare_graph_timing.cypher
```
Inspect the plan table:
* `db hits`: number of storage engine page/record accesses
* `time`: wall-clock query planning and execution time in ms
* `memory`: total peak bytes allocated during execution
