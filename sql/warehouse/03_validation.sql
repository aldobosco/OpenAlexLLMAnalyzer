SET search_path TO warehouse, public;

-- Fact rows must reconcile exactly with processed works.csv.
SELECT COUNT(*) AS fact_work_count FROM fact_work;

-- Each work has exactly one source/type/date foreign-key value, including explicit unknown members.
SELECT COUNT(*) AS facts_with_missing_dimension
FROM fact_work f
LEFT JOIN dim_date d ON d.date_key = f.date_key
LEFT JOIN dim_source s ON s.source_key = f.source_key
LEFT JOIN dim_work_type wt ON wt.work_type_key = f.work_type_key
WHERE d.date_key IS NULL OR s.source_key IS NULL OR wt.work_type_key IS NULL;

-- Bridge endpoint checks. Every result must be zero.
SELECT COUNT(*) AS orphan_topic_bridge
FROM bridge_work_topic b LEFT JOIN fact_work f ON f.work_key = b.work_key
WHERE f.work_key IS NULL;
SELECT COUNT(*) AS orphan_author_bridge
FROM bridge_work_author b LEFT JOIN fact_work f ON f.work_key = b.work_key
WHERE f.work_key IS NULL;
SELECT COUNT(*) AS orphan_institution_bridge
FROM bridge_work_institution b LEFT JOIN fact_work f ON f.work_key = b.work_key
WHERE f.work_key IS NULL;
SELECT COUNT(*) AS orphan_citation_bridge
FROM bridge_work_citation b
LEFT JOIN fact_work citing ON citing.work_key = b.citing_work_key
LEFT JOIN fact_work cited ON cited.work_key = b.cited_work_key
WHERE citing.work_key IS NULL OR cited.work_key IS NULL;

-- A work may have many topics, but at most one can be primary.
SELECT work_key, COUNT(*) AS primary_topic_count
FROM bridge_work_topic
WHERE is_primary_topic
GROUP BY work_key
HAVING COUNT(*) > 1;

-- Work-level totals must not use bridges and must reconcile with the source snapshot.
SELECT SUM(publication_count) AS publications, SUM(cited_by_count) AS citations
FROM fact_work;
