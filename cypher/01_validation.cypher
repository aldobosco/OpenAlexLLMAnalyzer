// V1 — entity-node reconciliation. Pilot expected: 638, 2396, 441, 123, 220.
MATCH (w:Work) WITH count(w) AS works
MATCH (a:Author) WITH works, count(a) AS authors
MATCH (i:Institution) WITH works, authors, count(i) AS institutions
MATCH (s:Source) WITH works, authors, institutions, count(s) AS sources
MATCH (t:Topic)
RETURN works, authors, institutions, sources, count(t) AS topics;

// V2 — relationship reconciliation. Pilot expected: 3027, 1894, 1866, 615, 240.
MATCH ()-[a:AUTHORED]->() WITH count(a) AS authored
MATCH ()-[af:AFFILIATED_WITH]->() WITH authored, count(af) AS affiliations
MATCH ()-[ht:HAS_TOPIC]->() WITH authored, affiliations, count(ht) AS has_topic
MATCH ()-[ps:PUBLISHED_IN]->() WITH authored, affiliations, has_topic, count(ps) AS published_in
MATCH ()-[c:CITES]->()
RETURN authored, affiliations, has_topic, published_in, count(c) AS cites;

// V3 — duplicate node IDs. All five values must be zero.
CALL {
  MATCH (n:Work) WITH n.id AS id, count(*) AS c WHERE c > 1 RETURN count(*) AS work_duplicates
}
CALL {
  MATCH (n:Author) WITH n.id AS id, count(*) AS c WHERE c > 1 RETURN count(*) AS author_duplicates
}
CALL {
  MATCH (n:Institution) WITH n.id AS id, count(*) AS c WHERE c > 1 RETURN count(*) AS institution_duplicates
}
CALL {
  MATCH (n:Source) WITH n.id AS id, count(*) AS c WHERE c > 1 RETURN count(*) AS source_duplicates
}
CALL {
  MATCH (n:Topic) WITH n.id AS id, count(*) AS c WHERE c > 1 RETURN count(*) AS topic_duplicates
}
RETURN work_duplicates, author_duplicates, institution_duplicates, source_duplicates, topic_duplicates;

// V4 — relationship endpoint labels and contextual-affiliation provenance.
CALL {
  MATCH (a)-[:AUTHORED]->(w)
  WHERE NOT a:Author OR NOT w:Work
  RETURN count(*) AS bad_authored_endpoints
}
CALL {
  MATCH (a)-[r:AFFILIATED_WITH]->(i)
  WHERE NOT a:Author OR NOT i:Institution OR r.work_id IS NULL
        OR NOT EXISTS { MATCH (:Work {id: r.work_id}) }
        OR NOT EXISTS { MATCH (a)-[:AUTHORED]->(:Work {id: r.work_id}) }
  RETURN count(*) AS bad_affiliation_context
}
CALL {
  MATCH (w)-[:HAS_TOPIC]->(t)
  WHERE NOT w:Work OR NOT t:Topic
  RETURN count(*) AS bad_topic_endpoints
}
CALL {
  MATCH (w)-[:PUBLISHED_IN]->(s)
  WHERE NOT w:Work OR NOT s:Source
  RETURN count(*) AS bad_source_endpoints
}
CALL {
  MATCH (a:Work)-[:CITES]->(b:Work) WHERE a = b
  RETURN count(*) AS citation_self_loops
}
RETURN bad_authored_endpoints, bad_affiliation_context,
       bad_topic_endpoints, bad_source_endpoints, citation_self_loops;

// V5 — duplicate logical relationship identities. Every value must be zero.
CALL {
  MATCH (a:Author)-[:AUTHORED]->(w:Work)
  WITH a.id AS author_id, w.id AS work_id, count(*) AS c WHERE c > 1
  RETURN count(*) AS duplicate_authored
}
CALL {
  MATCH (a:Author)-[r:AFFILIATED_WITH]->(i:Institution)
  WITH a.id AS author_id, r.work_id AS work_id, i.id AS institution_id, count(*) AS c WHERE c > 1
  RETURN count(*) AS duplicate_affiliations
}
CALL {
  MATCH (w:Work)-[:HAS_TOPIC]->(t:Topic)
  WITH w.id AS work_id, t.id AS topic_id, count(*) AS c WHERE c > 1
  RETURN count(*) AS duplicate_work_topics
}
CALL {
  MATCH (w:Work)-[r:PUBLISHED_IN]->(s:Source)
  WITH w.id AS work_id, s.id AS source_id, r.location_role AS location_role, count(*) AS c WHERE c > 1
  RETURN count(*) AS duplicate_work_sources
}
CALL {
  MATCH (a:Work)-[:CITES]->(b:Work)
  WITH a.id AS citing_work_id, b.id AS cited_work_id, count(*) AS c WHERE c > 1
  RETURN count(*) AS duplicate_citations
}
RETURN duplicate_authored, duplicate_affiliations, duplicate_work_topics,
       duplicate_work_sources, duplicate_citations;

// V6 — relationship property completeness/validity.
CALL {
  MATCH ()-[r:AUTHORED]->()
  WHERE r.author_position IS NULL OR r.author_order IS NULL OR r.is_corresponding IS NULL
  RETURN count(*) AS authored_missing_properties
}
CALL {
  MATCH ()-[r:HAS_TOPIC]->()
  WHERE r.is_primary_topic IS NULL
  RETURN count(*) AS topic_missing_primary_flag
}
CALL {
  MATCH ()-[r:PUBLISHED_IN]->()
  WHERE r.location_role IS NULL
  RETURN count(*) AS source_missing_location_role
}
CALL {
  MATCH (w:Work)-[r:HAS_TOPIC]->()
  WHERE r.is_primary_topic = true
  WITH w, count(*) AS c WHERE c > 1
  RETURN count(*) AS works_with_multiple_primary_topics
}
RETURN authored_missing_properties, topic_missing_primary_flag,
       source_missing_location_role, works_with_multiple_primary_topics;