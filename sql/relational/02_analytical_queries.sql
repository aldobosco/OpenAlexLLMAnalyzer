SET search_path TO openalex, public;

-- =============================================================================
-- Benchmark Evaluation Queries (matching scripts/evaluation/benchmark_comparison.py)
-- =============================================================================

-- Q1: LLM/Generative-AI Evolution by Year, Work Type, and Source
-- Roll-up and drill-down of works by publication year and work type with citation statistics.
SELECT
    publication_year,
    work_type,
    COUNT(*) AS work_count,
    ROUND(AVG(cited_by_count), 2) AS avg_cited_by_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY cited_by_count) AS median_cited_by_count
FROM works
GROUP BY publication_year, work_type
ORDER BY publication_year, work_type;

-- Q2A: Top 20 Authors Productivity (Aggregation)
-- Group-by over author-work relationships with citation sum and count.
SELECT
    a.author_id,
    a.display_name,
    COUNT(DISTINCT au.work_id) AS work_count,
    SUM(w.cited_by_count) AS summed_work_citations
FROM authors a
JOIN authorships au ON au.author_id = a.author_id
JOIN works w ON w.work_id = au.work_id
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
LIMIT 20;

-- Q2B: Top 20 Institutions (Contextual Affiliations)
-- Distinct work count and citations per institution.
WITH institution_works AS (
    SELECT DISTINCT institution_id, work_id
    FROM affiliations
)
SELECT
    i.institution_id,
    i.display_name,
    COUNT(*) AS work_count,
    SUM(w.cited_by_count) AS citations
FROM institution_works iw
JOIN institutions i ON i.institution_id = iw.institution_id
JOIN works w ON w.work_id = iw.work_id
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC, i.institution_id
LIMIT 20;

-- Q3: Topic-Field Roll-Up in 2020 (Dimensional Slicing)
-- Aggregation up the topic hierarchy filtered by publication year.
SELECT
    t.field_name,
    COUNT(DISTINCT wt.work_id) AS work_count,
    ROUND(AVG(w.cited_by_count), 2) AS avg_citations
FROM work_topics wt
JOIN topics t ON t.topic_id = wt.topic_id
JOIN works w ON w.work_id = wt.work_id
WHERE w.publication_year = 2020
GROUP BY t.field_name
ORDER BY work_count DESC;

-- Q4: Inter-Institution Collaboration (Diamond Join)
-- Pairs of institutions collaborating on works in year 2020.
WITH work_institutions AS (
    SELECT DISTINCT work_id, institution_id
    FROM affiliations
), institution_pairs AS (
    SELECT
        left_side.work_id,
        left_side.institution_id AS institution_1_id,
        right_side.institution_id AS institution_2_id
    FROM work_institutions left_side
    JOIN work_institutions right_side
      ON right_side.work_id = left_side.work_id
     AND right_side.institution_id > left_side.institution_id
)
SELECT
    i1.display_name AS institution_1,
    i2.display_name AS institution_2,
    COUNT(*) AS collaborative_work_count,
    SUM(w.cited_by_count) AS summed_work_citations
FROM institution_pairs p
JOIN works w ON w.work_id = p.work_id
JOIN institutions i1 ON i1.institution_id = p.institution_1_id
JOIN institutions i2 ON i2.institution_id = p.institution_2_id
WHERE w.publication_year = 2020
GROUP BY i1.display_name, i2.display_name
ORDER BY collaborative_work_count DESC, summed_work_citations DESC
LIMIT 30;

-- Q5: Directed Citation Paths 2–4 Hops (Path Traversal)
-- Multi-hop reachability along citation edges.
WITH RECURSIVE citation_paths AS (
    SELECT
        c.citing_work_id AS start_work_id,
        c.cited_work_id AS current_work_id,
        ARRAY[c.citing_work_id, c.cited_work_id]::TEXT[] AS path,
        1 AS hops
    FROM citations c
    UNION ALL
    SELECT
        p.start_work_id,
        c.cited_work_id,
        p.path || c.cited_work_id,
        p.hops + 1
    FROM citation_paths p
    JOIN citations c ON c.citing_work_id = p.current_work_id
    WHERE p.hops < 4
      AND NOT c.cited_work_id = ANY (p.path)
)
SELECT hops, COUNT(*) AS path_count
FROM citation_paths
WHERE hops BETWEEN 2 AND 4
GROUP BY hops
ORDER BY hops;

-- Q6: Co-Authorship Degree (Two-Hop Bipartite Expansion)
-- Author node degree over shared work co-authorship.
WITH coauthor_edges AS (
    SELECT DISTINCT
        LEAST(a1.author_id, a2.author_id) AS author_1_id,
        GREATEST(a1.author_id, a2.author_id) AS author_2_id
    FROM authorships a1
    JOIN authorships a2
      ON a1.work_id = a2.work_id
     AND a1.author_id < a2.author_id
), author_degree AS (
    SELECT author_1_id AS author_id, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_1_id
    UNION ALL
    SELECT author_2_id AS author_id, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_2_id
)
SELECT a.author_id, a.display_name, SUM(d.degree) AS coauthor_degree
FROM author_degree d
JOIN authors a ON a.author_id = d.author_id
GROUP BY a.author_id, a.display_name
ORDER BY coauthor_degree DESC, a.author_id
LIMIT 20;

-- =============================================================================
-- Supplementary Queries
-- =============================================================================

-- Q2C: Source productivity and impact (one primary location at most per work).
SELECT
    s.source_id,
    s.display_name,
    s.source_type,
    COUNT(*) AS work_count,
    ROUND(AVG(w.cited_by_count), 2) AS avg_cited_by_count,
    SUM(w.cited_by_count) AS total_cited_by_count
FROM sources s
JOIN work_sources ws ON ws.source_id = s.source_id
JOIN works w ON w.work_id = ws.work_id
GROUP BY s.source_id, s.display_name, s.source_type
ORDER BY work_count DESC, total_cited_by_count DESC, s.source_id
LIMIT 20;
