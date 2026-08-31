// P2A — PROFILE version of Q2A (top authors)
PROFILE
MATCH (a:Author)-[:AUTHORED]->(w:Work)
WITH a, collect(DISTINCT w) AS works
RETURN a.id AS author_id,
       size(works) AS work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY work_count DESC, total_work_citations DESC, author_id
LIMIT 20;

// P2B — PROFILE version of Q2B (top institutions)
PROFILE
MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
WITH i, collect(DISTINCT w) AS works
RETURN i.id AS institution_id,
       i.display_name AS institution_name,
       size(works) AS distinct_work_count,
       reduce(total = 0, w IN works | total + w.cited_by_count) AS total_work_citations
ORDER BY distinct_work_count DESC, total_work_citations DESC, institution_id
LIMIT 20;

// P4 — PROFILE version of Q4 (institution collaborations, 2020)
PROFILE
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