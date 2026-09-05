SET search_path TO warehouse, public;

-- Q1 (adapted): annual production and citation metrics by work type.
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

-- Q2A (adapted): most productive authors. Each work contributes fully to every author.
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

/* Q2D (adapted): replace :year and :'topic_id' with psql variables or literals.
SELECT
    a.author_id,
    a.display_name,
    SUM(f.publication_count) AS work_count,
    SUM(f.cited_by_count) AS summed_work_citations
FROM fact_work f
JOIN bridge_work_author bwa ON bwa.work_key = f.work_key
JOIN dim_author a ON a.author_key = bwa.author_key
JOIN bridge_work_topic bwt ON bwt.work_key = f.work_key AND bwt.is_primary_topic
JOIN dim_topic t ON t.topic_key = bwt.topic_key
WHERE f.publication_year = :year
  AND t.topic_id = :'topic_id'
GROUP BY a.author_id, a.display_name
ORDER BY work_count DESC, summed_work_citations DESC, a.author_id;
*/

-- Q2B (adapted): institution productivity. A work contributes fully to each distinct institution.
SELECT
    i.institution_id,
    i.display_name,
    i.country_code,
    SUM(f.publication_count) AS work_count,
    SUM(f.cited_by_count) AS total_cited_by_count,
    ROUND(AVG(f.cited_by_count), 2) AS avg_cited_by_count
FROM fact_work f
JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
JOIN dim_institution i ON i.institution_key = bwi.institution_key
GROUP BY i.institution_id, i.display_name, i.country_code
ORDER BY work_count DESC, total_cited_by_count DESC, i.institution_id
LIMIT 20;

-- Q2C (adapted): source productivity and impact. Unknown sources are retained explicitly.
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

-- Q4 (adapted): inter-institution collaboration by year. Each unordered pair appears once per work.
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
    f.publication_year,
    i1.display_name AS institution_1,
    i2.display_name AS institution_2,
    SUM(f.publication_count) AS collaborative_work_count,
    SUM(f.cited_by_count) AS summed_work_citations,
    ROUND(AVG(f.cited_by_count), 2) AS avg_work_citations
FROM institution_pairs p
JOIN fact_work f ON f.work_key = p.work_key
JOIN dim_institution i1 ON i1.institution_key = p.institution_1_key
JOIN dim_institution i2 ON i2.institution_key = p.institution_2_key
GROUP BY f.publication_year, i1.display_name, i2.display_name
ORDER BY collaborative_work_count DESC, summed_work_citations DESC
LIMIT 30;

-- Q3: topic-field growth. Full association counting is deliberate: one work assigned
-- to multiple topics contributes one full publication/citation value to each assignment.
SELECT
    f.publication_year,
    t.field_name,
    SUM(f.publication_count) AS topic_association_publications,
    SUM(f.cited_by_count) AS topic_association_citations,
    ROUND(AVG(f.cited_by_count), 2) AS avg_citations_per_association
FROM fact_work f
JOIN bridge_work_topic bwt ON bwt.work_key = f.work_key
JOIN dim_topic t ON t.topic_key = bwt.topic_key
GROUP BY f.publication_year, t.field_name
ORDER BY f.publication_year, topic_association_publications DESC;

-- Example: source and publisher performance by year.
SELECT
    f.publication_year,
    s.publisher,
    s.display_name AS source,
    SUM(f.publication_count) AS publications,
    SUM(f.cited_by_count) AS citations
FROM fact_work f
JOIN dim_source s ON s.source_key = f.source_key
GROUP BY f.publication_year, s.publisher, s.display_name
ORDER BY f.publication_year, publications DESC;

-- Example: institutional output by country. This is association-level output, not
-- a corpus-wide work total: multi-institution works are intentionally counted in every country.
SELECT
    f.publication_year,
    i.country_code,
    SUM(f.publication_count) AS institution_association_publications,
    SUM(f.cited_by_count) AS institution_association_citations
FROM fact_work f
JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
JOIN dim_institution i ON i.institution_key = bwi.institution_key
GROUP BY f.publication_year, i.country_code
ORDER BY f.publication_year, institution_association_publications DESC;

-- Example: annual open-access trend; fact-only query with no bridge multiplication.
SELECT
    f.publication_year,
    f.is_oa,
    SUM(f.publication_count) AS publications,
    ROUND(100.0 * SUM(f.publication_count) /
          SUM(SUM(f.publication_count)) OVER (PARTITION BY f.publication_year), 2) AS percent_of_year
FROM fact_work f
GROUP BY f.publication_year, f.is_oa
ORDER BY f.publication_year, f.is_oa;

/* Q5 (adapted): directed citation paths of 2--4 hops. This uses the factless
   citation bridge, not an OLAP aggregate. Replace :'start_work_id'.
WITH RECURSIVE citation_paths AS (
    SELECT c.citing_work_key AS start_work_key, c.cited_work_key AS current_work_key,
           ARRAY[c.citing_work_key, c.cited_work_key]::BIGINT[] AS path, 1 AS hops
    FROM bridge_work_citation c
    JOIN fact_work start_work ON start_work.work_key = c.citing_work_key
    WHERE start_work.work_id = :'start_work_id'
    UNION ALL
    SELECT p.start_work_key, c.cited_work_key, p.path || c.cited_work_key, p.hops + 1
    FROM citation_paths p
    JOIN bridge_work_citation c ON c.citing_work_key = p.current_work_key
    WHERE p.hops < 4 AND NOT c.cited_work_key = ANY (p.path)
)
SELECT start_work.work_id AS start_work_id, reached_work.work_id AS reached_work_id, p.hops, p.path
FROM citation_paths p
JOIN fact_work start_work ON start_work.work_key = p.start_work_key
JOIN fact_work reached_work ON reached_work.work_key = p.current_work_key
WHERE p.hops BETWEEN 2 AND 4
ORDER BY p.hops, reached_work.work_id;

-- Q6 (adapted): co-author degree inferred from the author bridge.
WITH coauthor_edges AS (
    SELECT DISTINCT LEAST(left_side.author_key, right_side.author_key) AS author_1_key,
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
LIMIT 25;
*/
