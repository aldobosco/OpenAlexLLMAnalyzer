-- Run each block independently after one warm-up. Compare PostgreSQL's final
-- "Execution Time" line only; both queries implement the same semantics.

SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.author_id, a.display_name,
       COUNT(DISTINCT au.work_id) AS work_count,
       SUM(w.cited_by_count) AS summed_work_citations
FROM authors a
JOIN authorships au ON au.author_id = a.author_id
JOIN works w ON w.work_id = au.work_id
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
LIMIT 20;

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.author_id, a.display_name,
       SUM(f.publication_count) AS work_count,
       SUM(f.cited_by_count) AS summed_work_citations
FROM fact_work f
JOIN bridge_work_author bwa ON bwa.work_key = f.work_key
JOIN dim_author a ON a.author_key = bwa.author_key
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
LIMIT 20;

SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
WITH institution_works AS (
    SELECT DISTINCT institution_id, work_id FROM affiliations
)
SELECT i.institution_id, i.display_name, COUNT(*) AS work_count, SUM(w.cited_by_count) AS citations
FROM institution_works iw
JOIN institutions i ON i.institution_id = iw.institution_id
JOIN works w ON w.work_id = iw.work_id
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC, i.institution_id
LIMIT 20;

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
SELECT i.institution_id, i.display_name,
       SUM(f.publication_count) AS work_count, SUM(f.cited_by_count) AS citations
FROM fact_work f
JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
JOIN dim_institution i ON i.institution_key = bwi.institution_key
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC, i.institution_id
LIMIT 20;

SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
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

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
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

-- Q4: Inter-institution collaboration in 2020 (diamond join pattern)
SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
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

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
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

-- Q5: Directed citation paths of 2 to 4 hops (recursive graph traversal in SQL)
SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
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

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
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

-- Q6: Co-authorship degree (two-hop bipartite expansion)
SET search_path TO openalex, public;
EXPLAIN (ANALYZE, BUFFERS)
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

SET search_path TO warehouse, public;
EXPLAIN (ANALYZE, BUFFERS)
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
