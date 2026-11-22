-- Тест схемы. Запускать ПОСЛЕ: 00_local_auth_stub.sql -> 01_catalog.sql -> 02_core.sql

-- =====================================================================
-- ЧАСТЬ 1. ХОРОШИЕ ДАННЫЕ — весь блок должен выполниться без ошибок
-- =====================================================================

INSERT INTO auth.users (id) VALUES
('00000000-0000-0000-0000-000000000001'),
('00000000-0000-0000-0000-000000000002'),
('00000000-0000-0000-0000-000000000003');

INSERT INTO profiles (id, email, full_name, program_id, year_of_study) VALUES
('00000000-0000-0000-0000-000000000001', 'b_zhanatuly@kbtu.kz', 'Bekzat', 1, 2);

INSERT INTO profiles (id, email, full_name, role) VALUES
('00000000-0000-0000-0000-000000000002', 'moderator@kbtu.kz', 'Moderator', 'moderator');

INSERT INTO materials (discipline_id, author_id, title, material_type, status)
SELECT id, '00000000-0000-0000-0000-000000000001', 'Транзакции и уровни изоляции', 'lecture_notes', 'published'
FROM disciplines WHERE code = 'CSCI2104';

INSERT INTO material_files (material_id, storage_path, file_name, mime_type, size_bytes)
VALUES (1, 'materials/1/transactions.pdf', 'transactions.pdf', 'application/pdf', 120000);

INSERT INTO ai_reviews (material_id, model, verdict, relevance_score, quality_score, tags)
VALUES (1, 'claude', 'ok', 0.95, 4, '{transactions, isolation}');

INSERT INTO likes (user_id, material_id) VALUES
('00000000-0000-0000-0000-000000000002', 1);

INSERT INTO comments (material_id, author_id, body) VALUES
(1, '00000000-0000-0000-0000-000000000002', 'Спасибо, очень помогло!');

INSERT INTO comments (material_id, author_id, parent_id, body) VALUES
(1, '00000000-0000-0000-0000-000000000001', 1, 'Пожалуйста!');

INSERT INTO reports (reporter_id, material_id, reason) VALUES
('00000000-0000-0000-0000-000000000002', 1, 'spam');

-- Проверка: карточка материала через представление
SELECT * FROM material_cards;


-- =====================================================================
-- ЧАСТЬ 2. ПЛОХИЕ ДАННЫЕ — запускай КАЖДУЮ команду ОТДЕЛЬНО.
-- Каждая должна выдать ERROR. Если какая-то прошла — в схеме дыра.
-- =====================================================================

-- 1. Почта не @kbtu.kz  -> profiles_email_check
INSERT INTO profiles (id, email, full_name)
VALUES ('00000000-0000-0000-0000-000000000003', 'student@gmail.com', 'Hacker');

-- 2. Повторный лайк того же материала  -> likes_pkey (duplicate key)
INSERT INTO likes (user_id, material_id)
VALUES ('00000000-0000-0000-0000-000000000002', 1);

-- 3. Жалоба сразу и на материал, и на комментарий  -> reports_check
INSERT INTO reports (reporter_id, material_id, comment_id, reason)
VALUES ('00000000-0000-0000-0000-000000000002', 1, 1, 'spam');

-- 4. Жалоба "решена", но без даты решения  -> reports_check1
INSERT INTO reports (reporter_id, material_id, reason, status)
VALUES ('00000000-0000-0000-0000-000000000002', 1, 'spam', 'resolved');

-- 5. Значок "проверено" без указания модератора  -> materials_check
UPDATE materials SET is_verified = TRUE WHERE id = 1;

-- 6. Файл больше 20 МБ  -> material_files_size_bytes_check
INSERT INTO material_files (material_id, storage_path, file_name, mime_type, size_bytes)
VALUES (1, 'materials/1/big.pdf', 'big.pdf', 'application/pdf', 50000000);

-- 7. Слишком короткое название материала  -> materials_title_check
INSERT INTO materials (discipline_id, title, material_type)
VALUES (1, 'ab', 'lab');


-- =====================================================================
-- БОНУС. Как сделать ПРАВИЛЬНО (эти команды должны пройти)
-- =====================================================================

-- Значок "проверено" вместе с модератором
UPDATE materials
SET is_verified = TRUE,
    verified_by = '00000000-0000-0000-0000-000000000002'
WHERE id = 1;

-- Закрыть жалобу с датой решения
UPDATE reports
SET status = 'resolved',
    resolved_by = '00000000-0000-0000-0000-000000000002',
    resolved_at = now()
WHERE id = 1;
