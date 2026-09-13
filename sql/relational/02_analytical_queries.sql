SET search_path TO openalex, public;

-- Q1: Annual production, mean citations, median citations, split by work type.
SELECT
    publication_year,
    work_type,
    COUNT(*) AS work_count,
    ROUND(AVG(cited_by_count), 2) AS avg_cited_by_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY cited_by_count) AS median_cited_by_count
FROM works
GROUP BY publication_year, work_type
ORDER BY publication_year, work_type;

-- Q2A: Most productive authors; citation total counts each work once per author.
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

-- Q2B: Most productive/cited institutions by authored works.
-- DISTINCT work_id avoids over-counting when a work has multiple affiliated authors from one institution.
WITH institution_works AS (
    SELECT DISTINCT institution_id, work_id
    FROM affiliations
)
SELECT
    i.institution_id,
    i.display_name,
    i.country_code,
    COUNT(*) AS work_count,
    SUM(w.cited_by_count) AS total_cited_by_count,
    ROUND(AVG(w.cited_by_count), 2) AS avg_cited_by_count
FROM institution_works iw
JOIN institutions i ON i.institution_id = iw.institution_id
JOIN works w ON w.work_id = iw.work_id
GROUP BY i.institution_id, i.display_name, i.country_code
ORDER BY work_count DESC, total_cited_by_count DESC, i.institution_id
LIMIT 20;

-- Q2C: Source productivity and impact (one primary location at most per work in current contract).
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

/*
-- Q2D: Author production/ranking for a given year and primary topic only.
-- Replace :year and :topic_id with psql variables or literals.
SELECT
    a.author_id,
    a.display_name,
    COUNT(DISTINCT w.work_id) AS work_count,
    SUM(w.cited_by_count) AS summed_work_citations
FROM works w
JOIN authorships au ON au.work_id = w.work_id
JOIN authors a ON a.author_id = au.author_id
JOIN work_topics wt ON wt.work_id = w.work_id AND wt.is_primary_topic
WHERE w.publication_year = :year
  AND wt.topic_id = :'topic_id'
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id;
*/

-- Q4: Inter-institution collaboration per publication year.
-- Each unordered institution pair is counted at most once per work.
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
    w.publication_year,
    i1.display_name AS institution_1,
    i2.display_name AS institution_2,
    COUNT(*) AS collaborative_work_count,
    SUM(w.cited_by_count) AS summed_work_citations,
    ROUND(AVG(w.cited_by_count), 2) AS avg_work_citations
FROM institution_pairs p
JOIN works w ON w.work_id = p.work_id
JOIN institutions i1 ON i1.institution_id = p.institution_1_id
JOIN institutions i2 ON i2.institution_id = p.institution_2_id
GROUP BY w.publication_year, i1.display_name, i2.display_name
ORDER BY collaborative_work_count DESC, summed_work_citations DESC
LIMIT 30;

/*
-- Q5 prototype: all directed citation paths with 2 to 4 hops from a selected work.
-- Replace :'start_work_id'. CYCLE prevents repeated work IDs inside a path.
WITH RECURSIVE citation_paths AS (
    SELECT
        c.citing_work_id AS start_work_id,
        c.cited_work_id AS current_work_id,
        ARRAY[c.citing_work_id, c.cited_work_id]::TEXT[] AS path,
        1 AS hops
    FROM citations c
    WHERE c.citing_work_id = :'start_work_id'

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
SELECT start_work_id, current_work_id AS reached_work_id, hops, path
FROM citation_paths
WHERE hops BETWEEN 2 AND 4
ORDER BY hops, reached_work_id;

-- Q6 prototype: co-author bridges inferred from authors sharing a work.
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
LIMIT 25;
*/
