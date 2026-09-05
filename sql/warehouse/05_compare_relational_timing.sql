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
