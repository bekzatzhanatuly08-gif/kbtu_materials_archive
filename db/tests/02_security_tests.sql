-- Тест безопасности. Запускать в ЧИСТОЙ базе через psql в таком порядке:
--   tests/00_local_auth_stub.sql -> 01_catalog.sql -> 02_core.sql -> 03_security.sql -> tests/02_security_tests.sql
-- В конце печатается таблица: каждая проверка должна быть PASS.

\set QUIET on
\pset pager off
\o /dev/null

-- =====================================================================
-- ИНСТРУМЕНТЫ ДЛЯ ТЕСТА
-- =====================================================================

CREATE SCHEMA tests;
GRANT USAGE ON SCHEMA tests TO anon, authenticated, service_role;

CREATE TABLE tests.results (n SERIAL, actor TEXT, label TEXT, passed BOOLEAN, detail TEXT);
GRANT SELECT, INSERT ON tests.results TO anon, authenticated, service_role;
GRANT USAGE ON SEQUENCE tests.results_n_seq TO anon, authenticated, service_role;

-- id пользователя / материала / комментария по человеческому признаку (видит всё)
CREATE FUNCTION tests.uid(p_email TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER
AS $$ SELECT id FROM auth.users WHERE email = p_email $$;
CREATE FUNCTION tests.mid(p_title TEXT) RETURNS INT LANGUAGE sql SECURITY DEFINER
AS $$ SELECT id FROM public.materials WHERE title = p_title $$;
CREATE FUNCTION tests.cid(p_body TEXT) RETURNS INT LANGUAGE sql SECURITY DEFINER
AS $$ SELECT id FROM public.comments WHERE body = p_body $$;

-- "Войти" под пользователем: кладём его id в JWT, как это делает Supabase
CREATE FUNCTION tests.login(p_email TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_email IS NULL THEN
        PERFORM set_config('request.jwt.claims', '{"role":"anon"}', false);
    ELSE
        PERFORM set_config('request.jwt.claims',
            json_build_object('sub', tests.uid(p_email), 'role', 'authenticated')::text, false);
    END IF;
END $$;

CREATE FUNCTION tests.email_of(p_id UUID) RETURNS TEXT LANGUAGE sql SECURITY DEFINER
AS $$ SELECT email FROM auth.users WHERE id = p_id $$;
CREATE FUNCTION tests.actor() RETURNS TEXT LANGUAGE sql
AS $$ SELECT current_user || coalesce(' ' || tests.email_of(auth.uid()), '') $$;

-- Команда должна выполниться без ошибки
CREATE FUNCTION tests.ok(p_label TEXT, p_sql TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, FALSE, SQLERRM);
        RETURN;
    END;
    INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, TRUE, 'ok');
END $$;

-- Команда должна быть отклонена с ошибкой
CREATE FUNCTION tests.fails(p_label TEXT, p_sql TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, TRUE, SQLERRM);
        RETURN;
    END;
    INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, FALSE, 'NO ERROR — command went through');
END $$;

-- Запрос должен вернуть ожидаемое значение (например, количество строк)
CREATE FUNCTION tests.equals(p_label TEXT, p_sql TEXT, p_expected TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql INTO v;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, FALSE, SQLERRM);
        RETURN;
    END;
    INSERT INTO tests.results (actor, label, passed, detail)
    VALUES (tests.actor(), p_label, v IS NOT DISTINCT FROM p_expected, 'got ' || coalesce(v, 'NULL') || ', expected ' || coalesce(p_expected, 'NULL'));
END $$;

-- UPDATE/DELETE должен затронуть ровно столько строк (RLS молча пропускает чужие строки)
CREATE FUNCTION tests.affects(p_label TEXT, p_sql TEXT, p_expected INT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    n INT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        GET DIAGNOSTICS n = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO tests.results (actor, label, passed, detail) VALUES (tests.actor(), p_label, FALSE, SQLERRM);
        RETURN;
    END;
    INSERT INTO tests.results (actor, label, passed, detail)
    VALUES (tests.actor(), p_label, n = p_expected, 'rows ' || n || ', expected ' || p_expected);
END $$;


-- =====================================================================
-- РЕГИСТРАЦИЯ (выполняет "Supabase Auth")
-- =====================================================================

SELECT tests.ok('Регистрация с @kbtu.kz',
    $$INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
      ('11111111-1111-1111-1111-111111111111', 'bekzat@kbtu.kz', '{"full_name":"Bekzat"}'),
      ('22222222-2222-2222-2222-222222222222', 'aru@kbtu.kz',    '{"full_name":"Aru"}'),
      ('33333333-3333-3333-3333-333333333333', 'mod@kbtu.kz',    '{}')$$);
SELECT tests.fails('Регистрация с gmail отклонена',
    $$INSERT INTO auth.users (id, email) VALUES ('44444444-4444-4444-4444-444444444444', 'hacker@gmail.com')$$);
SELECT tests.fails('Регистрация с поддельным доменом kbtu.kz.evil.com отклонена',
    $$INSERT INTO auth.users (id, email) VALUES ('55555555-5555-5555-5555-555555555555', 'x@kbtu.kz.evil.com')$$);
SELECT tests.fails('Регистрация без почты (по телефону) отклонена',
    $$INSERT INTO auth.users (id) VALUES ('66666666-6666-6666-6666-666666666666')$$);
SELECT tests.equals('Профили созданы автоматически', $$SELECT count(*) FROM public.profiles$$, '3');
SELECT tests.equals('Имя взято из формы регистрации', $$SELECT full_name FROM public.profiles WHERE email = 'aru@kbtu.kz'$$, 'Aru');
SELECT tests.equals('Без имени в форме берётся часть почты', $$SELECT full_name FROM public.profiles WHERE email = 'mod@kbtu.kz'$$, 'mod');
SELECT tests.equals('Новый пользователь — студент', $$SELECT role FROM public.profiles WHERE email = 'bekzat@kbtu.kz'$$, 'student');

-- Админ назначает модератора (вручную, в SQL Editor)
UPDATE public.profiles SET role = 'moderator' WHERE email = 'mod@kbtu.kz';


-- =====================================================================
-- ГОСТЬ (не вошёл)
-- =====================================================================

SELECT tests.login(NULL);
SET ROLE anon;
SELECT tests.equals('Гость видит каталог', $$SELECT count(*) FROM public.disciplines$$, '34');
SELECT tests.fails('Гость не видит материалы', $$SELECT count(*) FROM public.materials$$);
SELECT tests.fails('Гость не видит карточки материалов', $$SELECT count(*) FROM public.material_cards$$);
SELECT tests.fails('Гость не видит профили', $$SELECT count(*) FROM public.profiles$$);
SELECT tests.fails('Гость не может создать материал', $$INSERT INTO public.materials (discipline_id, title, material_type) VALUES (1, 'Guest', 'other')$$);
SELECT tests.fails('Гость не может вызвать модерацию', $$SELECT public.moderate_material(1, 'publish')$$);
RESET ROLE;


-- =====================================================================
-- СТУДЕНТ bekzat: профиль и материалы
-- =====================================================================

SELECT tests.login('bekzat@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Студент видит каталог', $$SELECT count(*) FROM public.disciplines$$, '34');
SELECT tests.affects('Студент меняет своё имя', $$UPDATE public.profiles SET full_name = 'Bekzat Zh.' WHERE id = auth.uid()$$, 1);
SELECT tests.fails('АТАКА: студент ставит себе роль admin', $$UPDATE public.profiles SET role = 'admin' WHERE id = auth.uid()$$);
SELECT tests.affects('АТАКА: студент меняет чужое имя (0 строк)', $$UPDATE public.profiles SET full_name = 'Hacked' WHERE id <> auth.uid()$$, 0);
SELECT tests.fails('Студент не видит чужие почты', $$SELECT email FROM public.profiles$$);
SELECT tests.equals('Студент видит имена других', $$SELECT count(full_name) FROM public.profiles$$, '3');
SELECT tests.fails('АТАКА: создать профиль вручную', $$INSERT INTO public.profiles (id, email, full_name) VALUES (gen_random_uuid(), 'fake@kbtu.kz', 'Fake')$$);

SELECT tests.ok('Студент загружает материал',
    $$INSERT INTO public.materials (discipline_id, title, material_type)
      SELECT id, 'Транзакции', 'lecture_notes' FROM public.disciplines WHERE code = 'CSCI2104'$$);
SELECT tests.ok('Студент загружает второй материал',
    $$INSERT INTO public.materials (discipline_id, title, material_type)
      SELECT id, 'Нормализация', 'summary' FROM public.disciplines WHERE code = 'CSCI2104'$$);
SELECT tests.equals('Новый материал получает статус pending', $$SELECT status FROM public.materials WHERE title = 'Транзакции'$$, 'pending');
SELECT tests.equals('Автор проставлен автоматически', $$SELECT author_id = auth.uid() FROM public.materials WHERE title = 'Транзакции'$$, 'true');
SELECT tests.fails('АТАКА: опубликовать в обход ИИ-проверки',
    $$INSERT INTO public.materials (discipline_id, title, material_type, status) VALUES (1, 'Bypass', 'other', 'published')$$);
SELECT tests.fails('АТАКА: поставить себе значок "проверено"',
    $$INSERT INTO public.materials (discipline_id, title, material_type, is_verified) VALUES (1, 'Bypass', 'other', true)$$);
SELECT tests.fails('АТАКА: загрузить материал от имени Aru',
    format($$INSERT INTO public.materials (discipline_id, title, material_type, author_id) VALUES (1, 'Fake', 'other', %L)$$, tests.uid('aru@kbtu.kz')));
SELECT tests.fails('АТАКА: сменить статус своего материала на published',
    $$UPDATE public.materials SET status = 'published' WHERE title = 'Транзакции'$$);

SELECT tests.ok('Автор прикрепляет файл в свою папку',
    format($$INSERT INTO public.material_files (material_id, storage_path, file_name, mime_type, size_bytes) VALUES (%s, %L, 'tx.pdf', 'application/pdf', 1000)$$,
           tests.mid('Транзакции'), tests.uid('bekzat@kbtu.kz') || '/' || tests.mid('Транзакции') || '/tx.pdf'));
SELECT tests.fails('АТАКА: путь файла в чужой папке',
    format($$INSERT INTO public.material_files (material_id, storage_path, file_name, mime_type, size_bytes) VALUES (%s, %L, 'x.pdf', 'application/pdf', 1000)$$,
           tests.mid('Транзакции'), tests.uid('aru@kbtu.kz') || '/' || tests.mid('Транзакции') || '/x.pdf'));
SELECT tests.fails('АТАКА: файл .exe',
    format($$INSERT INTO public.material_files (material_id, storage_path, file_name, mime_type, size_bytes) VALUES (%s, %L, 'virus.exe', 'application/x-msdownload', 1000)$$,
           tests.mid('Транзакции'), tests.uid('bekzat@kbtu.kz') || '/' || tests.mid('Транзакции') || '/virus.exe'));
SELECT tests.ok('Хранилище: загрузка в свою папку',
    format($$INSERT INTO storage.objects (bucket_id, name) VALUES ('materials', %L)$$,
           tests.uid('bekzat@kbtu.kz') || '/' || tests.mid('Транзакции') || '/tx.pdf'));
SELECT tests.fails('АТАКА: хранилище, загрузка в чужую папку',
    format($$INSERT INTO storage.objects (bucket_id, name) VALUES ('materials', %L)$$,
           tests.uid('aru@kbtu.kz') || '/' || tests.mid('Транзакции') || '/x.pdf'));
SELECT tests.fails('АТАКА: ИИ-проверку пишет студент',
    format($$INSERT INTO public.ai_reviews (material_id, model, verdict) VALUES (%s, 'fake', 'ok')$$, tests.mid('Транзакции')));
RESET ROLE;


-- =====================================================================
-- СТУДЕНТ aru: чужие материалы на проверке не видны
-- =====================================================================

SELECT tests.login('aru@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Aru не видит чужие материалы на проверке', $$SELECT count(*) FROM public.materials$$, '0');
SELECT tests.equals('Aru не видит файлы чужих материалов на проверке', $$SELECT count(*) FROM public.material_files$$, '0');
SELECT tests.equals('Aru не видит эти файлы в хранилище', $$SELECT count(*) FROM storage.objects$$, '0');
SELECT tests.fails('АТАКА: лайк материалу на проверке',
    format($$INSERT INTO public.likes (material_id) VALUES (%s)$$, tests.mid('Транзакции')));
SELECT tests.fails('АТАКА: комментарий к материалу на проверке',
    format($$INSERT INTO public.comments (material_id, body) VALUES (%s, 'hi')$$, tests.mid('Транзакции')));
SELECT tests.affects('АТАКА: удалить чужой материал (0 строк)', $$DELETE FROM public.materials$$, 0);
SELECT tests.fails('АТАКА: Aru вызывает модерацию', format($$SELECT public.moderate_material(%s, 'publish')$$, tests.mid('Транзакции')));
RESET ROLE;


-- =====================================================================
-- МОДЕРАТОР: видит всё, публикует
-- =====================================================================

SELECT tests.login('mod@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Модератор видит материалы на проверке', $$SELECT count(*) FROM public.materials$$, '2');
SELECT tests.ok('Модератор публикует материал', format($$SELECT public.moderate_material(%s, 'publish')$$, tests.mid('Транзакции')));
SELECT tests.fails('Неизвестное действие модерации отклонено', format($$SELECT public.moderate_material(%s, 'delete_all')$$, tests.mid('Транзакции')));
RESET ROLE;

-- "Сервер" записывает результат ИИ-проверки
INSERT INTO public.ai_reviews (material_id, model, verdict, quality_score) VALUES (tests.mid('Транзакции'), 'claude', 'ok', 4);


-- =====================================================================
-- СТУДЕНТ aru: лайки, комментарии, жалобы на опубликованный материал
-- =====================================================================

SELECT tests.login('aru@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Aru видит опубликованный материал', $$SELECT count(*) FROM public.materials$$, '1');
SELECT tests.equals('Aru видит его карточку', $$SELECT likes_count || '/' || ai_verdict FROM public.material_cards$$, '0/ok');
SELECT tests.equals('Aru видит файл опубликованного материала в хранилище', $$SELECT count(*) FROM storage.objects$$, '1');
SELECT tests.ok('Aru ставит лайк', format($$INSERT INTO public.likes (material_id) VALUES (%s)$$, tests.mid('Транзакции')));
SELECT tests.fails('Повторный лайк отклонён', format($$INSERT INTO public.likes (material_id) VALUES (%s)$$, tests.mid('Транзакции')));
SELECT tests.fails('АТАКА: лайк от имени Bekzat',
    format($$INSERT INTO public.likes (user_id, material_id) VALUES (%L, %s)$$, tests.uid('bekzat@kbtu.kz'), tests.mid('Транзакции')));
SELECT tests.ok('Aru пишет комментарий', format($$INSERT INTO public.comments (material_id, body) VALUES (%s, 'Отличный конспект')$$, tests.mid('Транзакции')));
SELECT tests.ok('Aru правит комментарий в течение 15 минут',
    $$UPDATE public.comments SET body = 'Отличный конспект!' WHERE body = 'Отличный конспект'$$);
SELECT tests.equals('Появилась пометка "изменено"', $$SELECT edited_at IS NOT NULL FROM public.comments WHERE body = 'Отличный конспект!'$$, 'true');
SELECT tests.fails('АТАКА: комментарий от имени Bekzat',
    format($$INSERT INTO public.comments (material_id, author_id, body) VALUES (%s, %L, 'fake')$$, tests.mid('Транзакции'), tests.uid('bekzat@kbtu.kz')));
SELECT tests.fails('АТАКА: подделать дату комментария',
    format($$INSERT INTO public.comments (material_id, body, created_at) VALUES (%s, 'old', now() - interval '1 year')$$, tests.mid('Транзакции')));
SELECT tests.ok('Aru жалуется на материал',
    format($$INSERT INTO public.reports (material_id, reason) VALUES (%s, 'incorrect_content')$$, tests.mid('Транзакции')));
SELECT tests.fails('Повторная открытая жалоба отклонена',
    format($$INSERT INTO public.reports (material_id, reason) VALUES (%s, 'spam')$$, tests.mid('Транзакции')));
SELECT tests.fails('АТАКА: жалоба от имени Bekzat',
    format($$INSERT INTO public.reports (reporter_id, material_id, reason) VALUES (%L, %s, 'spam')$$, tests.uid('bekzat@kbtu.kz'), tests.mid('Транзакции')));
SELECT tests.fails('АТАКА: Aru сама закрывает жалобу', $$SELECT public.resolve_report(1, 'dismissed')$$);
RESET ROLE;


-- =====================================================================
-- СТУДЕНТ bekzat: ответ, чужие комментарии, редактирование материала
-- =====================================================================

SELECT tests.login('bekzat@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Bekzat видит, кто поставил лайк', $$SELECT count(user_id) FROM public.likes$$, '1');
SELECT tests.ok('Bekzat отвечает на комментарий',
    format($$INSERT INTO public.comments (material_id, parent_id, body) VALUES (%s, %s, 'Спасибо!')$$, tests.mid('Транзакции'), tests.cid('Отличный конспект!')));
SELECT tests.fails('АТАКА: ответ, привязанный к другому материалу',
    format($$INSERT INTO public.comments (material_id, parent_id, body) VALUES (%s, %s, 'x')$$, tests.mid('Нормализация'), tests.cid('Отличный конспект!')));
SELECT tests.affects('АТАКА: править чужой комментарий (0 строк)', $$UPDATE public.comments SET body = 'Hacked' WHERE body = 'Отличный конспект!'$$, 0);
SELECT tests.affects('АТАКА: удалить чужой лайк (0 строк)', $$DELETE FROM public.likes$$, 0);
SELECT tests.equals('Bekzat не видит чужие жалобы', $$SELECT count(*) FROM public.reports$$, '0');
SELECT tests.fails('АТАКА: жёстко удалить комментарий', $$DELETE FROM public.comments$$);
SELECT tests.affects('Bekzat правит свой опубликованный материал', $$UPDATE public.materials SET title = 'Транзакции (v2)' WHERE title = 'Транзакции'$$, 1);
SELECT tests.equals('После правки материал снова на проверке', $$SELECT status FROM public.materials WHERE title = 'Транзакции (v2)'$$, 'pending');
RESET ROLE;


-- =====================================================================
-- Правило 15 минут: делаем комментарий "старым"
-- =====================================================================

UPDATE public.comments SET created_at = now() - interval '20 minutes' WHERE body = 'Спасибо!';

SELECT tests.login('bekzat@kbtu.kz');
SET ROLE authenticated;
SELECT tests.fails('Правка через 20 минут отклонена', $$UPDATE public.comments SET body = 'Спасибо!!' WHERE body = 'Спасибо!'$$);
SELECT tests.ok('Удалить старый комментарий можно', $$UPDATE public.comments SET is_deleted = true WHERE body = 'Спасибо!'$$);
SELECT tests.equals('Текст удалённого комментария скрыт', $$SELECT count(*) FROM public.comments WHERE body = '[удалено]' AND is_deleted$$, '1');
SELECT tests.fails('Восстановить удалённый комментарий нельзя', $$UPDATE public.comments SET is_deleted = false WHERE is_deleted$$);
RESET ROLE;


-- =====================================================================
-- МОДЕРАТОР: жалобы, значок, скрытие, чужие комментарии
-- =====================================================================

SELECT tests.login('mod@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Модератор видит все жалобы', $$SELECT count(*) FROM public.reports$$, '1');
SELECT tests.ok('Модератор закрывает жалобу', $$SELECT public.resolve_report((SELECT min(id) FROM public.reports), 'resolved')$$);
SELECT tests.equals('У закрытой жалобы есть дата решения', $$SELECT resolved_at IS NOT NULL FROM public.reports$$, 'true');
SELECT tests.fails('Повторно закрыть жалобу нельзя', $$SELECT public.resolve_report((SELECT min(id) FROM public.reports), 'dismissed')$$);
SELECT tests.fails('Значок на неопубликованный материал не ставится', format($$SELECT public.moderate_material(%s, 'verify')$$, tests.mid('Транзакции (v2)')));
SELECT tests.ok('Модератор снова публикует', format($$SELECT public.moderate_material(%s, 'publish')$$, tests.mid('Транзакции (v2)')));
SELECT tests.ok('Модератор ставит значок "проверено"', format($$SELECT public.moderate_material(%s, 'verify')$$, tests.mid('Транзакции (v2)')));
SELECT tests.fails('АТАКА: модератор переписывает чужой комментарий', $$UPDATE public.comments SET body = 'Edited by mod' WHERE body = 'Отличный конспект!'$$);
SELECT tests.ok('Модератор удаляет чужой комментарий', $$UPDATE public.comments SET is_deleted = true WHERE body = 'Отличный конспект!'$$);
SELECT tests.fails('АТАКА: модератор назначает себя админом', $$UPDATE public.profiles SET role = 'admin' WHERE id = auth.uid()$$);
SELECT tests.ok('Модератор скрывает материал', format($$SELECT public.moderate_material(%s, 'hide')$$, tests.mid('Транзакции (v2)')));
RESET ROLE;


-- =====================================================================
-- Скрытый материал: автор не может "раскрыть" его правкой
-- =====================================================================

SELECT tests.login('bekzat@kbtu.kz');
SET ROLE authenticated;
SELECT tests.affects('Автор правит скрытый материал', $$UPDATE public.materials SET title = 'Транзакции (v3)' WHERE title = 'Транзакции (v2)'$$, 1);
SELECT tests.equals('Материал остался скрытым', $$SELECT status FROM public.materials WHERE title = 'Транзакции (v3)'$$, 'hidden');
SELECT tests.ok('Автор удаляет свой материал', $$DELETE FROM public.materials WHERE title = 'Нормализация'$$);
RESET ROLE;

SELECT tests.login('aru@kbtu.kz');
SET ROLE authenticated;
SELECT tests.equals('Aru не видит скрытый материал', $$SELECT count(*) FROM public.materials$$, '0');
SELECT tests.equals('Aru не видит комментарии скрытого материала', $$SELECT count(*) FROM public.comments$$, '0');
RESET ROLE;


-- =====================================================================
-- Новый файл к опубликованному материалу = правка: снова на проверку
-- =====================================================================

SELECT tests.login('mod@kbtu.kz');
SET ROLE authenticated;
SELECT tests.ok('Модератор возвращает материал в публикацию', format($$SELECT public.moderate_material(%s, 'publish')$$, tests.mid('Транзакции (v3)')));
RESET ROLE;

SELECT tests.login('bekzat@kbtu.kz');
SET ROLE authenticated;
SELECT tests.ok('Автор добавляет файл к опубликованному материалу',
    format($$INSERT INTO public.material_files (material_id, storage_path, file_name, mime_type, size_bytes) VALUES (%s, %L, 'extra.png', 'image/png', 500)$$,
           tests.mid('Транзакции (v3)'), tests.uid('bekzat@kbtu.kz') || '/' || tests.mid('Транзакции (v3)') || '/extra.png'));
SELECT tests.equals('Материал снова на проверке', $$SELECT status FROM public.materials WHERE title = 'Транзакции (v3)'$$, 'pending');
RESET ROLE;


-- =====================================================================
-- СЕРВЕР (service_role): записывает результат ИИ-проверки
-- =====================================================================

SELECT tests.login(NULL);
SET ROLE service_role;
SELECT tests.ok('Сервер записывает ИИ-проверку',
    format($$INSERT INTO public.ai_reviews (material_id, model, verdict, quality_score) VALUES (%s, 'claude', 'ok', 5)$$, tests.mid('Транзакции (v3)')));
SELECT tests.affects('Сервер публикует материал после проверки',
    $$UPDATE public.materials SET status = 'published' WHERE title = 'Транзакции (v3)'$$, 1);
RESET ROLE;


-- =====================================================================
-- СМЕНА ПОЧТЫ (выполняет "Supabase Auth")
-- =====================================================================

SELECT tests.login(NULL);
SELECT tests.fails('Смена почты на gmail отклонена', $$UPDATE auth.users SET email = 'aru@gmail.com' WHERE email = 'aru@kbtu.kz'$$);
SELECT tests.ok('Смена почты внутри kbtu.kz', $$UPDATE auth.users SET email = 'aru.new@kbtu.kz' WHERE email = 'aru@kbtu.kz'$$);
SELECT tests.equals('Почта в профиле обновилась', $$SELECT count(*) FROM public.profiles WHERE email = 'aru.new@kbtu.kz'$$, '1');


-- =====================================================================
-- ИТОГ
-- =====================================================================

\o
\set QUIET off
SELECT n, CASE WHEN passed THEN 'PASS' ELSE '>>> FAIL' END AS result, label, actor, detail
FROM tests.results ORDER BY n;

SELECT count(*) FILTER (WHERE passed) AS passed, count(*) FILTER (WHERE NOT passed) AS failed, count(*) AS total
FROM tests.results;
