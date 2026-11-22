-- KBTU Materials Archive — core: users, materials, AI reviews, likes, comments, reports
-- Requires 01_catalog.sql. Written for Supabase: auth.users is created by Supabase Auth.

CREATE TABLE profiles (
    id            UUID         PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email         VARCHAR(255) NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@kbtu\.kz$'),
    full_name     VARCHAR(150) NOT NULL,
    program_id    INT          REFERENCES programs(id),
    year_of_study SMALLINT     CHECK (year_of_study BETWEEN 1 AND 4),
    role          VARCHAR(20)  NOT NULL DEFAULT 'student'
                  CHECK (role IN ('student', 'moderator', 'admin')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE materials (
    id            SERIAL       PRIMARY KEY,
    discipline_id INT          NOT NULL REFERENCES disciplines(id),
    author_id     UUID         REFERENCES profiles(id) ON DELETE SET NULL,
    title         VARCHAR(200) NOT NULL CHECK (length(trim(title)) >= 3),
    description   TEXT,
    material_type VARCHAR(30)  NOT NULL
                  CHECK (material_type IN ('lecture_notes', 'exam_questions', 'lab', 'assignment', 'summary', 'other')),
    language      VARCHAR(2)   NOT NULL DEFAULT 'ru' CHECK (language IN ('en', 'ru', 'kk')),
    academic_year VARCHAR(9)   CHECK (academic_year ~ '^\d{4}-\d{4}$'),
    status        VARCHAR(20)  NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'published', 'rejected', 'hidden')),
    is_verified   BOOLEAN      NOT NULL DEFAULT FALSE,
    verified_by   UUID         REFERENCES profiles(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (is_verified = FALSE OR verified_by IS NOT NULL)
);

CREATE TABLE material_files (
    id           SERIAL       PRIMARY KEY,
    material_id  INT          NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
    storage_path TEXT         NOT NULL UNIQUE,
    file_name    VARCHAR(255) NOT NULL,
    mime_type    VARCHAR(100) NOT NULL,
    size_bytes   BIGINT       NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 20971520),
    uploaded_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE ai_reviews (
    id              SERIAL       PRIMARY KEY,
    material_id     INT          NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
    model           VARCHAR(100) NOT NULL,
    verdict         VARCHAR(20)  NOT NULL CHECK (verdict IN ('ok', 'needs_attention', 'irrelevant')),
    relevance_score NUMERIC(3,2) CHECK (relevance_score BETWEEN 0 AND 1),
    quality_score   SMALLINT     CHECK (quality_score BETWEEN 1 AND 5),
    summary         TEXT,
    issues          TEXT,
    tags            TEXT[]       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE likes (
    user_id     UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    material_id INT         NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, material_id)
);

CREATE TABLE comments (
    id          SERIAL      PRIMARY KEY,
    material_id INT         NOT NULL REFERENCES materials(id) ON DELETE CASCADE,
    author_id   UUID        REFERENCES profiles(id) ON DELETE SET NULL,
    parent_id   INT         REFERENCES comments(id) ON DELETE CASCADE,
    body        TEXT        NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 2000),
    is_deleted  BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE reports (
    id          SERIAL      PRIMARY KEY,
    reporter_id UUID        REFERENCES profiles(id) ON DELETE SET NULL,
    material_id INT         REFERENCES materials(id) ON DELETE CASCADE,
    comment_id  INT         REFERENCES comments(id) ON DELETE CASCADE,
    reason      VARCHAR(30) NOT NULL
                CHECK (reason IN ('wrong_discipline', 'incorrect_content', 'copyright', 'spam', 'offensive', 'other')),
    details     TEXT,
    status      VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
    resolved_by UUID        REFERENCES profiles(id) ON DELETE SET NULL,
    resolved_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((material_id IS NULL) <> (comment_id IS NULL)),
    CHECK ((status = 'open') = (resolved_at IS NULL))
);

CREATE INDEX idx_materials_discipline_status ON materials (discipline_id, status);
CREATE INDEX idx_materials_author           ON materials (author_id);
CREATE INDEX idx_material_files_material    ON material_files (material_id);
CREATE INDEX idx_ai_reviews_material        ON ai_reviews (material_id);
CREATE INDEX idx_likes_material             ON likes (material_id);
CREATE INDEX idx_comments_material          ON comments (material_id);
CREATE INDEX idx_reports_open               ON reports (status) WHERE status = 'open';

CREATE VIEW material_cards AS
SELECT
    m.id,
    m.title,
    m.material_type,
    m.language,
    m.is_verified,
    m.created_at,
    d.code    AS discipline_code,
    d.name_ru AS discipline_name,
    p.full_name AS author_name,
    (SELECT count(*) FROM likes l    WHERE l.material_id = m.id)                       AS likes_count,
    (SELECT count(*) FROM comments c WHERE c.material_id = m.id AND NOT c.is_deleted) AS comments_count,
    (SELECT r.verdict FROM ai_reviews r WHERE r.material_id = m.id
     ORDER BY r.created_at DESC LIMIT 1)                                               AS ai_verdict
FROM materials m
JOIN disciplines d ON d.id = m.discipline_id
LEFT JOIN profiles p ON p.id = m.author_id
WHERE m.status = 'published';
