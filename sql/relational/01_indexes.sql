BEGIN;
SET search_path TO openalex, public;

CREATE INDEX idx_works_publication_year ON works (publication_year);
CREATE INDEX idx_works_type_year ON works (work_type, publication_year);
CREATE INDEX idx_authorships_author_work ON authorships (author_id, work_id);
CREATE INDEX idx_affiliations_institution ON affiliations (institution_id, work_id, author_id);
CREATE INDEX idx_work_topics_topic_work ON work_topics (topic_id, work_id);
CREATE INDEX idx_work_topics_primary ON work_topics (topic_id, work_id)
    WHERE is_primary_topic;
CREATE INDEX idx_work_sources_source_work ON work_sources (source_id, work_id);
CREATE INDEX idx_citations_cited_citing ON citations (cited_work_id, citing_work_id);
CREATE INDEX idx_citations_citing_cited ON citations (citing_work_id, cited_work_id);

ANALYZE;
COMMIT;