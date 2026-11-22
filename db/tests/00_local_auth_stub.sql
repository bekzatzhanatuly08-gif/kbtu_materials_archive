-- ТОЛЬКО ДЛЯ ЛОКАЛЬНОГО ТЕСТА. В Supabase этот файл НЕ запускать:
-- там роли, схема auth и схема storage уже существуют.
-- Создаём упрощённую "заглушку" Supabase, чтобы схема работала в обычном PostgreSQL.

-- Роли, от имени которых Supabase выполняет запросы с сайта
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN BYPASSRLS;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- Схема auth: пользователи и функция auth.uid()
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE TABLE auth.users (
    id                 UUID PRIMARY KEY,
    email              TEXT,
    raw_user_meta_data JSONB NOT NULL DEFAULT '{}'
);

-- Как в Supabase: id текущего пользователя берётся из JWT-токена запроса
CREATE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE
AS $$
    SELECT coalesce(
        nullif(current_setting('request.jwt.claim.sub', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    )::uuid;
$$;

-- Схема storage: хранилище файлов
CREATE SCHEMA storage;
GRANT USAGE ON SCHEMA storage TO anon, authenticated;

CREATE TABLE storage.buckets (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL,
    public             BOOLEAN DEFAULT FALSE,
    file_size_limit    BIGINT,
    allowed_mime_types TEXT[]
);

CREATE TABLE storage.objects (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id TEXT REFERENCES storage.buckets(id),
    name      TEXT,
    owner     UUID DEFAULT auth.uid()
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON storage.buckets TO anon, authenticated;
GRANT ALL ON storage.objects TO anon, authenticated;

-- Как в Supabase: 'a/b/file.pdf' -> {a, b}
CREATE FUNCTION storage.foldername(name TEXT) RETURNS TEXT[]
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    _parts TEXT[];
BEGIN
    _parts := string_to_array(name, '/');
    RETURN _parts[1:array_length(_parts, 1) - 1];
END;
$$;
