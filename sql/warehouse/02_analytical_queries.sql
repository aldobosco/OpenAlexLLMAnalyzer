SET search_path TO warehouse, public;

-- =============================================================================
-- Benchmark Evaluation Queries (matching scripts/evaluation/benchmark_comparison.py)
-- =============================================================================

-- Q1: LLM/Generative-AI Evolution by Year, Work Type, and Source
-- Roll-up and drill-down of works by publication year and work type with citation statistics.
SELECT
    f.publication_year,
    wt.work_type,
    SUM(f.publication_count) AS work_count,
    ROUND(AVG(f.cited_by_count), 2) AS avg_cited_by_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY f.cited_by_count) AS median_cited_by_count
FROM fact_work f
JOIN dim_work_type wt ON wt.work_type_key = f.work_type_key
GROUP BY f.publication_year, wt.work_type
ORDER BY f.publication_year, wt.work_type;

-- Q2A: Top 20 Authors Productivity (Aggregation)
-- Group-by over author-work relationships with citation sum and count.
SELECT
    a.author_id,
    a.display_name,
    SUM(f.publication_count) AS work_count,
    SUM(f.cited_by_count) AS summed_work_citations
FROM fact_work f
JOIN bridge_work_author bwa ON bwa.work_key = f.work_key
JOIN dim_author a ON a.author_key = bwa.author_key
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
LIMIT 20;

-- Q2B: Top 20 Institutions (Contextual Affiliations)
-- Distinct work count and citations per institution.
SELECT
    i.institution_id,
    i.display_name,
    SUM(f.publication_count) AS work_count,
    SUM(f.cited_by_count) AS citations
FROM fact_work f
JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
JOIN dim_institution i ON i.institution_key = bwi.institution_key
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC, i.institution_id
LIMIT 20;

-- Q3: Topic-Field Roll-Up in 2020 (Dimensional Slicing)
-- Aggregation up the topic hierarchy filtered by publication year.
SELECT
    t.field_name,
    COUNT(DISTINCT f.work_key) AS work_count,
    ROUND(AVG(f.cited_by_count), 2) AS avg_citations
FROM fact_work f
JOIN bridge_work_topic bwt ON bwt.work_key = f.work_key
JOIN dim_topic t ON t.topic_key = bwt.topic_key
WHERE f.publication_year = 2020
GROUP BY t.field_name
ORDER BY work_count DESC;

-- Q4: Inter-Institution Collaboration (Diamond Join)
-- Pairs of institutions collaborating on works in year 2020.
WITH institution_pairs AS (
    SELECT
        left_side.work_key,
        left_side.institution_key AS institution_1_key,
        right_side.institution_key AS institution_2_key
    FROM bridge_work_institution left_side
    JOIN bridge_work_institution right_side
      ON right_side.work_key = left_side.work_key
     AND right_side.institution_key > left_side.institution_key
)
SELECT
    i1.display_name AS institution_1,
    i2.display_name AS institution_2,
    SUM(f.publication_count) AS collaborative_work_count,
    SUM(f.cited_by_count) AS summed_work_citations
FROM institution_pairs p
JOIN fact_work f ON f.work_key = p.work_key
JOIN dim_institution i1 ON i1.institution_key = p.institution_1_key
JOIN dim_institution i2 ON i2.institution_key = p.institution_2_key
WHERE f.publication_year = 2020
GROUP BY i1.display_name, i2.display_name
ORDER BY collaborative_work_count DESC, summed_work_citations DESC
LIMIT 30;

-- Q5: Directed Citation Paths 2–4 Hops (Path Traversal)
-- Multi-hop reachability along citation edges via factless citation bridge.
WITH RECURSIVE citation_paths AS (
    SELECT
        c.citing_work_key AS start_work_key,
        c.cited_work_key AS current_work_key,
        ARRAY[c.citing_work_key, c.cited_work_key]::BIGINT[] AS path,
        1 AS hops
    FROM bridge_work_citation c
    UNION ALL
    SELECT
        p.start_work_key,
        c.cited_work_key,
        p.path || c.cited_work_key,
        p.hops + 1
    FROM citation_paths p
    JOIN bridge_work_citation c ON c.citing_work_key = p.current_work_key
    WHERE p.hops < 4
      AND NOT c.cited_work_key = ANY (p.path)
)
SELECT hops, COUNT(*) AS path_count
FROM citation_paths
WHERE hops BETWEEN 2 AND 4
GROUP BY hops
ORDER BY hops;

-- Q6: Co-Authorship Degree (Two-Hop Bipartite Expansion)
-- Author node degree over shared work co-authorship via author bridge.
WITH coauthor_edges AS (
    SELECT DISTINCT
        LEAST(left_side.author_key, right_side.author_key) AS author_1_key,
        GREATEST(left_side.author_key, right_side.author_key) AS author_2_key
    FROM bridge_work_author left_side
    JOIN bridge_work_author right_side
      ON right_side.work_key = left_side.work_key
     AND right_side.author_key > left_side.author_key
), author_degree AS (
    SELECT author_1_key AS author_key, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_1_key
    UNION ALL
    SELECT author_2_key AS author_key, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_2_key
)
SELECT a.author_id, a.display_name, SUM(d.degree) AS coauthor_degree
FROM author_degree d
JOIN dim_author a ON a.author_key = d.author_key
GROUP BY a.author_id, a.display_name
ORDER BY coauthor_degree DESC, a.author_id
LIMIT 20;

-- =============================================================================
-- Supplementary Queries
-- =============================================================================

-- Q2C: Source productivity and impact.
SELECT
    s.source_id,
    s.display_name,
    s.source_type,
    SUM(f.publication_count) AS work_count,
    ROUND(AVG(f.cited_by_count), 2) AS avg_cited_by_count,
    SUM(f.cited_by_count) AS total_cited_by_count
FROM fact_work f
JOIN dim_source s ON s.source_key = f.source_key
GROUP BY s.source_id, s.display_name, s.source_type
ORDER BY work_count DESC, total_cited_by_count DESC, s.source_id
LIMIT 20;
