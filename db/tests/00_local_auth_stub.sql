-- ТОЛЬКО ДЛЯ ЛОКАЛЬНОГО ТЕСТА. В Supabase этот файл НЕ запускать:
-- там схема auth и таблица auth.users уже существуют.
-- Создаём упрощённую "заглушку", чтобы 02_core.sql работал в обычном PostgreSQL.

CREATE SCHEMA auth;

CREATE TABLE auth.users (
    id UUID PRIMARY KEY
);
