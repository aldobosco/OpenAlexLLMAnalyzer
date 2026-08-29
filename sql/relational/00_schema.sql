BEGIN;

DROP SCHEMA IF EXISTS openalex CASCADE;
CREATE SCHEMA openalex;
SET search_path TO openalex, public;

CREATE TABLE works (
    work_id          TEXT PRIMARY KEY,
    doi              TEXT,
    title            TEXT NOT NULL,
    abstract          TEXT,
    publication_date DATE,
    publication_year SMALLINT,
    work_type        TEXT NOT NULL,
    language         TEXT,
    cited_by_count   INTEGER NOT NULL DEFAULT 0,
    is_oa            BOOLEAN,
    oa_status        TEXT,
    CONSTRAINT works_id_format_ck CHECK (work_id ~ '^W[0-9]+$'),
    CONSTRAINT works_publication_year_ck CHECK (
        publication_year IS NULL OR publication_year BETWEEN 1900 AND 2100
    ),
    CONSTRAINT works_cited_by_count_ck CHECK (cited_by_count >= 0),
    CONSTRAINT works_date_year_ck CHECK (
        publication_date IS NULL
        OR publication_year IS NULL
        OR EXTRACT(YEAR FROM publication_date)::SMALLINT = publication_year
    )
);

CREATE TABLE authors (
    author_id    TEXT PRIMARY KEY,
    display_name TEXT,
    CONSTRAINT authors_id_format_ck CHECK (author_id ~ '^A[0-9]+$')
);

CREATE TABLE institutions (
    institution_id   TEXT PRIMARY KEY,
    display_name     TEXT,
    country_code     CHAR(2),
    institution_type TEXT,
    CONSTRAINT institutions_id_format_ck CHECK (institution_id ~ '^I[0-9]+$'),
    CONSTRAINT institutions_country_code_ck CHECK (
        country_code IS NULL OR country_code ~ '^[A-Z]{2}$'
    )
);

CREATE TABLE sources (
    source_id    TEXT PRIMARY KEY,
    display_name TEXT,
    source_type  TEXT,
    issn_l       TEXT,
    issn         TEXT,
    publisher    TEXT,
    CONSTRAINT sources_id_format_ck CHECK (source_id ~ '^S[0-9]+$')
);

CREATE TABLE topics (
    topic_id      TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL,
    subfield_id   TEXT,
    subfield_name TEXT,
    field_id      TEXT,
    field_name    TEXT,
    domain_id     TEXT,
    domain_name   TEXT,
    CONSTRAINT topics_id_format_ck CHECK (topic_id ~ '^T[0-9]+$')
);

CREATE TABLE authorships (
    work_id          TEXT NOT NULL,
    author_id        TEXT NOT NULL,
    author_position  TEXT,
    author_order     INTEGER NOT NULL,
    is_corresponding BOOLEAN,
    PRIMARY KEY (work_id, author_id),
    CONSTRAINT authorships_work_fk FOREIGN KEY (work_id)
        REFERENCES works (work_id) ON DELETE RESTRICT,
    CONSTRAINT authorships_author_fk FOREIGN KEY (author_id)
        REFERENCES authors (author_id) ON DELETE RESTRICT,
    CONSTRAINT authorships_order_ck CHECK (author_order >= 1),
    CONSTRAINT authorships_position_ck CHECK (
        author_position IS NULL OR author_position IN ('first', 'middle', 'last', 'single')
    )
);

CREATE TABLE affiliations (
    work_id        TEXT NOT NULL,
    author_id      TEXT NOT NULL,
    institution_id TEXT NOT NULL,
    PRIMARY KEY (work_id, author_id, institution_id),
    CONSTRAINT affiliations_authorship_fk FOREIGN KEY (work_id, author_id)
        REFERENCES authorships (work_id, author_id) ON DELETE RESTRICT,
    CONSTRAINT affiliations_institution_fk FOREIGN KEY (institution_id)
        REFERENCES institutions (institution_id) ON DELETE RESTRICT
);

CREATE TABLE work_topics (
    work_id          TEXT NOT NULL,
    topic_id         TEXT NOT NULL,
    score            NUMERIC(7,6),
    is_primary_topic BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (work_id, topic_id),
    CONSTRAINT work_topics_work_fk FOREIGN KEY (work_id)
        REFERENCES works (work_id) ON DELETE RESTRICT,
    CONSTRAINT work_topics_topic_fk FOREIGN KEY (topic_id)
        REFERENCES topics (topic_id) ON DELETE RESTRICT,
    CONSTRAINT work_topics_score_ck CHECK (score IS NULL OR score BETWEEN 0 AND 1)
);

CREATE TABLE work_sources (
    work_id       TEXT NOT NULL,
    source_id     TEXT NOT NULL,
    location_role TEXT NOT NULL,
    PRIMARY KEY (work_id, source_id, location_role),
    CONSTRAINT work_sources_work_fk FOREIGN KEY (work_id)
        REFERENCES works (work_id) ON DELETE RESTRICT,
    CONSTRAINT work_sources_source_fk FOREIGN KEY (source_id)
        REFERENCES sources (source_id) ON DELETE RESTRICT,
    CONSTRAINT work_sources_role_ck CHECK (location_role = 'primary_location')
);

CREATE TABLE citations (
    citing_work_id TEXT NOT NULL,
    cited_work_id  TEXT NOT NULL,
    PRIMARY KEY (citing_work_id, cited_work_id),
    CONSTRAINT citations_citing_work_fk FOREIGN KEY (citing_work_id)
        REFERENCES works (work_id) ON DELETE RESTRICT,
    CONSTRAINT citations_cited_work_fk FOREIGN KEY (cited_work_id)
        REFERENCES works (work_id) ON DELETE RESTRICT,
    CONSTRAINT citations_no_self_loop_ck CHECK (citing_work_id <> cited_work_id)
);

COMMIT;