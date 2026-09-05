BEGIN;
SET search_path TO warehouse, public;

CREATE INDEX idx_fact_work_year_type ON fact_work (publication_year, work_type_key);
CREATE INDEX idx_fact_work_source ON fact_work (source_key);
CREATE INDEX idx_fact_work_date ON fact_work (date_key);
CREATE INDEX idx_bridge_topic_topic_work ON bridge_work_topic (topic_key, work_key);
CREATE INDEX idx_bridge_topic_primary ON bridge_work_topic (topic_key, work_key)
    WHERE is_primary_topic;
CREATE INDEX idx_bridge_author_author_work ON bridge_work_author (author_key, work_key);
CREATE INDEX idx_bridge_institution_institution_work
    ON bridge_work_institution (institution_key, work_key);
CREATE INDEX idx_bridge_citation_cited_citing
    ON bridge_work_citation (cited_work_key, citing_work_key);

ANALYZE;
COMMIT;
