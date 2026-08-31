// G1 — distribution of citation-path lengths (2–4 hops) from random start works.
// For each Work with outgoing citations, count how many 2–4 hop simple paths exist.
MATCH (start:Work)-[:CITES]->()
WITH start
MATCH p = (start)-[:CITES*2..4]->(target:Work)
WHERE all(n IN nodes(p) WHERE single(m IN nodes(p) WHERE m = n))
RETURN length(p) AS hops,
       count(p) AS path_count
ORDER BY hops;

// G2 — for each Work, count how many other Works share at least one topic.
MATCH (w1:Work)-[:HAS_TOPIC]->(t:Topic)<-[:HAS_TOPIC]-(w2:Work)
WHERE w1 <> w2
WITH w1, count(DISTINCT w2) AS related_work_count
RETURN related_work_count,
       count(*) AS num_works_with_that_count
ORDER BY related_work_count DESC;

// G3 — authors connecting distinct institutions through work-contextual affiliations.
// Count how many distinct institution pairs each author connects via different works.
MATCH (a:Author)-[af1:AFFILIATED_WITH]->(i1:Institution)
MATCH (a)-[af2:AFFILIATED_WITH]->(i2:Institution)
WHERE i1.id < i2.id AND af1.work_id <> af2.work_id
WITH a, count(DISTINCT [i1.id, i2.id]) AS institution_pair_count
RETURN a.id AS author_id,
       a.display_name AS author_name,
       institution_pair_count
ORDER BY institution_pair_count DESC, author_id
LIMIT 20;

// G4 — basic citation-network degree stats.
MATCH (w:Work)
OPTIONAL MATCH (w)-[:CITES]->(out)
OPTIONAL MATCH (inw)-[:CITES]->(w)
WITH w,
     count(DISTINCT out) AS out_degree,
     count(DISTINCT inw) AS in_degree
RETURN out_degree,
       in_degree,
       count(*) AS num_works
ORDER BY out_degree DESC, in_degree DESC;