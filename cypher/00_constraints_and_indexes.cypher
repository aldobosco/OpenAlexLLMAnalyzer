CREATE CONSTRAINT work_id_unique IF NOT EXISTS
FOR (n:Work) REQUIRE n.id IS UNIQUE;

CREATE CONSTRAINT author_id_unique IF NOT EXISTS
FOR (n:Author) REQUIRE n.id IS UNIQUE;

CREATE CONSTRAINT institution_id_unique IF NOT EXISTS
FOR (n:Institution) REQUIRE n.id IS UNIQUE;

CREATE CONSTRAINT source_id_unique IF NOT EXISTS
FOR (n:Source) REQUIRE n.id IS UNIQUE;

CREATE CONSTRAINT topic_id_unique IF NOT EXISTS
FOR (n:Topic) REQUIRE n.id IS UNIQUE;

// The uniqueness constraints already back exact-ID lookups.
// Add only workload-driven secondary indexes.
CREATE INDEX work_publication_year IF NOT EXISTS
FOR (n:Work) ON (n.publication_year);

CREATE INDEX work_type_year IF NOT EXISTS
FOR (n:Work) ON (n.work_type, n.publication_year);

CREATE INDEX work_citations IF NOT EXISTS
FOR (n:Work) ON (n.cited_by_count);