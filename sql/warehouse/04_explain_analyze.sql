SET search_path TO warehouse, public;

-- Run after sql/warehouse/01_indexes.sql. Execution Time is reported by PostgreSQL.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT a.author_id, a.display_name,
       SUM(f.publication_count) AS work_count,
       SUM(f.cited_by_count) AS summed_work_citations
FROM fact_work f
JOIN bridge_work_author bwa ON bwa.work_key = f.work_key
JOIN dim_author a ON a.author_key = bwa.author_key
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
LIMIT 20;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT i.institution_id, i.display_name,
       SUM(f.publication_count) AS work_count,
       SUM(f.cited_by_count) AS citations
FROM fact_work f
JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
JOIN dim_institution i ON i.institution_key = bwi.institution_key
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC, i.institution_id
LIMIT 20;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT f.publication_year, t.field_name,
       SUM(f.publication_count) AS publications,
       ROUND(AVG(f.cited_by_count), 2) AS avg_citations
FROM fact_work f
JOIN bridge_work_topic bwt ON bwt.work_key = f.work_key
JOIN dim_topic t ON t.topic_key = bwt.topic_key
WHERE f.publication_year = 2020
GROUP BY f.publication_year, t.field_name
ORDER BY publications DESC;
