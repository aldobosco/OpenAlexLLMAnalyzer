// Q1 — annual publication and citation metrics by work type.
MATCH (w:Work)
RETURN w.publication_year AS publication_year,
       w.work_type AS work_type,
       count(w) AS work_count,
       avg(toFloat(w.cited_by_count)) AS mean_citations,
       percentileCont(toFloat(w.cited_by_count), 0.5) AS median_citations
ORDER BY publication_year, work_type;

// Q2A — top authors by distinct works and summed Work cited_by_count.
MATCH (a:Author)-[:AUTHORED]->(w:Work)
WITH a, collect(DISTINCT w) AS works
RETURN a.id AS author_id,
       a.display_name AS author_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY work_count DESC, total_work_citations DESC, author_id
LIMIT 20;

// Q2B — top institutions. DISTINCT (Institution, Work) prevents double-counting
// when several authors on the same Work have the same institution.
MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
WITH i, collect(DISTINCT w) AS works
RETURN i.id AS institution_id,
       i.display_name AS institution_name,
       size(works) AS distinct_work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY distinct_work_count DESC, total_work_citations DESC, institution_id
LIMIT 20;

// Q2C — top publication sources by work count and summed citations.
MATCH (w:Work)-[:PUBLISHED_IN]->(s:Source)
WITH s, collect(DISTINCT w) AS works
RETURN s.id AS source_id,
       s.display_name AS source_name,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY work_count DESC, total_work_citations DESC, source_id
LIMIT 20;

// Q4 — unordered institution pairs co-occurring on a Work in year 2020.
MATCH (a1:Author)-[af1:AFFILIATED_WITH]->(i1:Institution)
MATCH (a1)-[:AUTHORED]->(w:Work {id: af1.work_id, publication_year: 2020})
MATCH (a2:Author)-[af2:AFFILIATED_WITH]->(i2:Institution)
MATCH (a2)-[:AUTHORED]->(w)
WHERE i1.id < i2.id
WITH i1, i2, collect(DISTINCT w) AS works
RETURN i1.id AS institution_1_id,
       i2.id AS institution_2_id,
       size(works) AS distinct_work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY distinct_work_count DESC, total_work_citations DESC, institution_1_id, institution_2_id;

// Q6 — co-author degree from distinct unordered author pairs.
MATCH (a1:Author)-[:AUTHORED]->(w:Work)<-[:AUTHORED]-(a2:Author)
WHERE a1.id < a2.id
WITH a1, collect(DISTINCT a2) AS coauthors
RETURN a1.id AS author_id,
       a1.display_name AS author_name,
       size(coauthors) AS coauthor_degree
ORDER BY coauthor_degree DESC, author_id;