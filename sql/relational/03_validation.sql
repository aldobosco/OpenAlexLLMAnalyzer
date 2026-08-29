SET search_path TO openalex, public;

-- A. Expected pilot row counts: replace values with etl_quality_report.json after a final ETL run.
WITH expected(table_name, expected_count) AS (
    VALUES
        ('works', 638::BIGINT),
        ('authors', 2396::BIGINT),
        ('institutions', 441::BIGINT),
        ('sources', 123::BIGINT),
        ('topics', 220::BIGINT),
        ('authorships', 3027::BIGINT),
        ('affiliations', 1894::BIGINT),
        ('work_topics', 1866::BIGINT),
        ('work_sources', 615::BIGINT),
        ('citations', 240::BIGINT)
), actual(table_name, actual_count) AS (
    SELECT 'works', COUNT(*) FROM works UNION ALL
    SELECT 'authors', COUNT(*) FROM authors UNION ALL
    SELECT 'institutions', COUNT(*) FROM institutions UNION ALL
    SELECT 'sources', COUNT(*) FROM sources UNION ALL
    SELECT 'topics', COUNT(*) FROM topics UNION ALL
    SELECT 'authorships', COUNT(*) FROM authorships UNION ALL
    SELECT 'affiliations', COUNT(*) FROM affiliations UNION ALL
    SELECT 'work_topics', COUNT(*) FROM work_topics UNION ALL
    SELECT 'work_sources', COUNT(*) FROM work_sources UNION ALL
    SELECT 'citations', COUNT(*) FROM citations
)
SELECT e.table_name, e.expected_count, a.actual_count,
       (e.expected_count = a.actual_count) AS reconciled
FROM expected e
JOIN actual a USING (table_name)
ORDER BY e.table_name;

-- B. Duplicate logical keys: all must be empty because PKs reject them.
SELECT work_id, author_id, COUNT(*) FROM authorships GROUP BY 1,2 HAVING COUNT(*) > 1;
SELECT work_id, author_id, institution_id, COUNT(*) FROM affiliations GROUP BY 1,2,3 HAVING COUNT(*) > 1;
SELECT work_id, topic_id, COUNT(*) FROM work_topics GROUP BY 1,2 HAVING COUNT(*) > 1;
SELECT work_id, source_id, location_role, COUNT(*) FROM work_sources GROUP BY 1,2,3 HAVING COUNT(*) > 1;
SELECT citing_work_id, cited_work_id, COUNT(*) FROM citations GROUP BY 1,2 HAVING COUNT(*) > 1;

-- C. Citation self-loops: must be 0.
SELECT COUNT(*) AS citation_self_loops
FROM citations
WHERE citing_work_id = cited_work_id;

-- D. Cross-check ETL relationship endpoint guarantee. Each must return 0.
SELECT COUNT(*) AS orphan_authorship_work
FROM authorships au LEFT JOIN works w USING (work_id) WHERE w.work_id IS NULL;
SELECT COUNT(*) AS orphan_authorship_author
FROM authorships au LEFT JOIN authors a USING (author_id) WHERE a.author_id IS NULL;
SELECT COUNT(*) AS orphan_affiliation_authorship
FROM affiliations af LEFT JOIN authorships au USING (work_id, author_id) WHERE au.work_id IS NULL;
SELECT COUNT(*) AS orphan_affiliation_institution
FROM affiliations af LEFT JOIN institutions i USING (institution_id) WHERE i.institution_id IS NULL;
SELECT COUNT(*) AS orphan_topic_work
FROM work_topics wt LEFT JOIN works w USING (work_id) WHERE w.work_id IS NULL;
SELECT COUNT(*) AS orphan_topic_topic
FROM work_topics wt LEFT JOIN topics t USING (topic_id) WHERE t.topic_id IS NULL;
SELECT COUNT(*) AS orphan_source_work
FROM work_sources ws LEFT JOIN works w USING (work_id) WHERE w.work_id IS NULL;
SELECT COUNT(*) AS orphan_source_source
FROM work_sources ws LEFT JOIN sources s USING (source_id) WHERE s.source_id IS NULL;
SELECT COUNT(*) AS orphan_citation_citing
FROM citations c LEFT JOIN works w ON w.work_id = c.citing_work_id WHERE w.work_id IS NULL;
SELECT COUNT(*) AS orphan_citation_cited
FROM citations c LEFT JOIN works w ON w.work_id = c.cited_work_id WHERE w.work_id IS NULL;

-- E. At most one primary topic per work. Returns empty if respected.
SELECT work_id, COUNT(*) AS primary_topic_count
FROM work_topics
WHERE is_primary_topic
GROUP BY work_id
HAVING COUNT(*) > 1;