SET search_path TO openalex, public;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    a.author_id, a.display_name,
    COUNT(DISTINCT au.work_id) AS work_count,
    SUM(w.cited_by_count) AS summed_work_citations
FROM authors a
JOIN authorships au ON au.author_id = a.author_id
JOIN works w ON w.work_id = au.work_id
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC
LIMIT 20;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
WITH institution_works AS (
    SELECT DISTINCT institution_id, work_id FROM affiliations
)
SELECT i.display_name, COUNT(*) AS work_count, SUM(w.cited_by_count) AS citations
FROM institution_works iw
JOIN institutions i ON i.institution_id = iw.institution_id
JOIN works w ON w.work_id = iw.work_id
GROUP BY i.institution_id, i.display_name
ORDER BY work_count DESC, citations DESC
LIMIT 20;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
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
