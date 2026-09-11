// ==============================================================================
// 05_compare_graph_timing.cypher
//
// Neo4j PROFILE counterparts for cross-paradigm performance evaluation.
// Matches the exact analytical workloads evaluated in:
//   - sql/warehouse/05_compare_relational_timing.sql (Relational vs Warehouse)
//
// HOW TO EVALUATE:
// Run each block independently in Neo4j Browser or cypher-shell after 1 warm-up.
// Metrics to record from Neo4j PROFILE output:
//   1. Wall-clock execution time (ms)
//   2. Total database hits (db hits)
//   3. Peak allocated memory (Bytes)
//   4. Row counts per operator
// ==============================================================================

// ------------------------------------------------------------------------------
// WORKLOAD 1 (Q2A): Top 20 authors by distinct works and summed citations
// Paradigmatic contrast:
//   - Relational/Warehouse: Fast HashAggregate on integers/strings.
//   - Graph: Requires collecting nodes into memory arrays and invoking reduce().
// ------------------------------------------------------------------------------
PROFILE
MATCH (a:Author)-[:AUTHORED]->(w:Work)
WITH a, collect(DISTINCT w) AS works
RETURN a.id AS author_id,
       a.display_name AS author_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS summed_work_citations
ORDER BY work_count DESC, summed_work_citations DESC, author_id
LIMIT 20;

// ------------------------------------------------------------------------------
// WORKLOAD 2 (Q2B): Top 20 institutions by distinct works and citations
// Paradigmatic contrast:
//   - Relational: Needs CTE with DISTINCT on affiliations to avoid multi-author inflation.
//   - Warehouse: Reads pre-deduplicated bridge_work_institution.
//   - Graph: Contextual traversal matching af.work_id = w.id on the edge.
// ------------------------------------------------------------------------------
PROFILE
MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
WITH i, collect(DISTINCT w) AS works
RETURN i.id AS institution_id,
       i.display_name AS institution_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS citations
ORDER BY work_count DESC, citations DESC, institution_id
LIMIT 20;

// ------------------------------------------------------------------------------
// WORKLOAD 3 (Q3): Topic-field aggregation rolled up for publication year 2020
// Paradigmatic contrast:
//   - Warehouse (Winner): Immediate partition/year filter on fact_work, compact star-join.
//   - Relational: Joins 3 tables with UUIDs.
//   - Graph (Disadvantage): Must evaluate publication_year property on all Work nodes,
//     traverse :HAS_TOPIC, and aggregate without columnar/vectorized engines.
// ------------------------------------------------------------------------------
PROFILE
MATCH (w:Work {publication_year: 2020})-[:HAS_TOPIC]->(t:Topic)
WITH t.field_name AS field_name, collect(DISTINCT w) AS works
RETURN field_name,
       size(works) AS work_count,
       round(avg([w IN works | toFloat(w.cited_by_count)]), 2) AS avg_citations
ORDER BY work_count DESC;

// ------------------------------------------------------------------------------
// WORKLOAD 4 (Q4): Inter-institution collaboration in 2020 (Diamond pattern)
// Paradigmatic contrast:
//   - Relational/Warehouse: Self-joins on affiliations / bridge tables.
//   - Graph: Multi-path pattern match (a1)-[af1]->(i1), (a1)->(w)<-(a2), (a2)-[af2]->(i2).
// ------------------------------------------------------------------------------
PROFILE
MATCH (a1:Author)-[af1:AFFILIATED_WITH]->(i1:Institution)
MATCH (a1)-[:AUTHORED]->(w:Work {id: af1.work_id, publication_year: 2020})
MATCH (a2:Author)-[af2:AFFILIATED_WITH]->(i2:Institution)
MATCH (a2)-[:AUTHORED]->(w)
WHERE i1.id < i2.id
WITH i1, i2, collect(DISTINCT w) AS works
RETURN i1.display_name AS institution_1,
       i2.display_name AS institution_2,
       size(works) AS collaborative_work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS summed_work_citations
ORDER BY collaborative_work_count DESC, summed_work_citations DESC
LIMIT 30;

// ------------------------------------------------------------------------------
// WORKLOAD 5 (Q5): Directed citation paths of 2 to 4 hops (Multi-hop path traversal)
// Paradigmatic contrast:
//   - Graph (Winner by Orders of Magnitude): Index-free adjacency pointer chasing (*2..4).
//     Traverses memory references directly without join lookups or cycle tracking tables.
//   - Relational/Warehouse: Exponential expansion in WITH RECURSIVE, maintaining array paths,
//     repeated B-Tree index scans, high buffer memory pressure.
// ------------------------------------------------------------------------------
PROFILE
MATCH p = (start:Work)-[:CITES*2..4]->(target:Work)
    WHERE reduce(seen = [], n IN nodes(p) | 
        CASE WHEN n IN seen THEN seen ELSE seen + n END
    ) = nodes(p)
RETURN length(p) AS hops, count(p) AS path_count
ORDER BY hops;



// ------------------------------------------------------------------------------
// WORKLOAD 6 (Q6): Co-authorship degree (Two-hop bipartite expansion)
// Paradigmatic contrast:
//   - Graph: Direct pattern (a1)-[:AUTHORED]->(w)<-[:AUTHORED]-(a2) following pointers.
//   - Relational/Warehouse: Self-joining junction/bridge tables on work keys with GROUP BY.
// ------------------------------------------------------------------------------
PROFILE
MATCH (a1:Author)-[:AUTHORED]->(w:Work)<-[:AUTHORED]-(a2:Author)
WHERE a1.id < a2.id
WITH a1, collect(DISTINCT a2) AS coauthors
RETURN a1.id AS author_id,
       a1.display_name AS author_name,
       size(coauthors) AS coauthor_degree
ORDER BY coauthor_degree DESC, author_id
LIMIT 20;
