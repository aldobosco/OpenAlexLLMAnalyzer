// =============================================================================
// Benchmark Evaluation Queries (matching scripts/evaluation/benchmark_comparison.py)
// =============================================================================

// Q1: LLM/Generative-AI Evolution by Year, Work Type, and Source
// Roll-up and drill-down of works by publication year and work type with citation statistics.
MATCH (w:Work)
RETURN w.publication_year AS publication_year,
       w.work_type AS work_type,
       count(w) AS work_count,
       avg(toFloat(w.cited_by_count)) AS mean_citations,
       percentileCont(toFloat(w.cited_by_count), 0.5) AS median_citations
ORDER BY publication_year, work_type;

// Q2A: Top 20 Authors Productivity (Aggregation)
// Group-by over author-work relationships with citation sum and count.
MATCH (a:Author)-[:AUTHORED]->(w:Work)
WITH a, collect(DISTINCT w) AS works
RETURN a.id AS author_id,
       a.display_name AS author_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS summed_work_citations
ORDER BY work_count DESC, summed_work_citations DESC, author_id
LIMIT 20;

// Q2B: Top 20 Institutions (Contextual Affiliations)
// Distinct work count and citations per institution.
MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
WITH i, collect(DISTINCT w) AS works
RETURN i.id AS institution_id,
       i.display_name AS institution_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS citations
ORDER BY work_count DESC, citations DESC, institution_id
LIMIT 20;

// Q3: Topic-Field Roll-Up in 2020 (Dimensional Slicing)
// Aggregation up the topic hierarchy filtered by publication year.
MATCH (w:Work {publication_year: 2020})-[:HAS_TOPIC]->(t:Topic)
WITH DISTINCT w, t.field_name AS field_name
RETURN field_name,
       count(w) AS work_count,
       round(avg(w.cited_by_count), 2) AS avg_citations
ORDER BY work_count DESC;

// Q4: Inter-Institution Collaboration (Diamond Join)
// Pairs of institutions collaborating on works in year 2020.
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

// Q5: Directed Citation Paths 2–4 Hops (Path Traversal)
// Multi-hop reachability along citation edges.
MATCH p = (start:Work)-[:CITES*2..4]->(target:Work)
WHERE reduce(seen = [], n IN nodes(p) | 
        CASE WHEN n IN seen THEN seen ELSE seen + n END
      ) = nodes(p)
RETURN length(p) AS hops, count(p) AS path_count
ORDER BY hops;

// Q6: Co-Authorship Degree (Two-Hop Bipartite Expansion)
// Author node degree over shared work co-authorship.
MATCH (a1:Author)-[:AUTHORED]->(w:Work)<-[:AUTHORED]-(a2:Author)
WHERE a1.id < a2.id
WITH a1, collect(DISTINCT a2) AS coauthors
RETURN a1.id AS author_id,
       a1.display_name AS author_name,
       size(coauthors) AS coauthor_degree
ORDER BY coauthor_degree DESC, author_id
LIMIT 20;

// =============================================================================
// Supplementary Queries
// =============================================================================

// Q2C: Source productivity and impact
MATCH (w:Work)-[:PUBLISHED_IN]->(s:Source)
WITH s, collect(DISTINCT w) AS works
RETURN s.id AS source_id,
       s.display_name AS source_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY work_count DESC, total_work_citations DESC, source_id
LIMIT 20;