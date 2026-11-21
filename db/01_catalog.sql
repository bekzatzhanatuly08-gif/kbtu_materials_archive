-- KBTU Materials Archive — catalog: schools, programs, disciplines
-- Source: Working Curriculum 6B06101 Information Systems, intake 2025-2026

CREATE TABLE schools (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20)  NOT NULL UNIQUE,
    name_en     VARCHAR(200) NOT NULL,
    name_ru     VARCHAR(200) NOT NULL
);

CREATE TABLE programs (
    id          SERIAL PRIMARY KEY,
    school_id   INT          NOT NULL REFERENCES schools(id),
    code        VARCHAR(20)  NOT NULL UNIQUE,
    name_en     VARCHAR(200) NOT NULL,
    name_ru     VARCHAR(200) NOT NULL,
    intake_year VARCHAR(9)   NOT NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE disciplines (
    id           SERIAL PRIMARY KEY,
    code         VARCHAR(50)  NOT NULL UNIQUE,
    name_en      VARCHAR(255) NOT NULL,
    name_ru      VARCHAR(255) NOT NULL,
    name_kk      VARCHAR(255),
    credits      SMALLINT     NOT NULL CHECK (credits > 0),
    cycle        VARCHAR(2)   NOT NULL CHECK (cycle IN ('G', 'C', 'S', 'FA')),
    control_form VARCHAR(30)  NOT NULL,
    kind         VARCHAR(20)  NOT NULL DEFAULT 'course'
                 CHECK (kind IN ('course', 'internship', 'attestation'))
);

CREATE TABLE program_disciplines (
    program_id    INT        NOT NULL REFERENCES programs(id) ON DELETE CASCADE,
    discipline_id INT        NOT NULL REFERENCES disciplines(id) ON DELETE CASCADE,
    semester      SMALLINT   NOT NULL CHECK (semester BETWEEN 1 AND 8),
    component     VARCHAR(2) CHECK (component IN ('RC', 'UC', 'EC')),
    PRIMARY KEY (program_id, discipline_id, semester)
);

CREATE TABLE prerequisites (
    discipline_id   INT NOT NULL REFERENCES disciplines(id) ON DELETE CASCADE,
    prerequisite_id INT NOT NULL REFERENCES disciplines(id) ON DELETE CASCADE,
    PRIMARY KEY (discipline_id, prerequisite_id),
    CHECK (discipline_id <> prerequisite_id)
);

INSERT INTO schools (code, name_en, name_ru) VALUES
('SITE', 'School of Information Technology and Engineering', 'Школа информационных технологий и инженерии');

INSERT INTO programs (school_id, code, name_en, name_ru, intake_year)
SELECT id, '6B06101', 'Information Systems', 'Информационные системы', '2025-2026'
FROM schools WHERE code = 'SITE';

INSERT INTO disciplines (code, name_en, name_ru, credits, cycle, control_form, kind) VALUES
('CSCI1103', 'Programming Principles 1', 'Принципы программирования 1', 6, 'C', 'Exam', 'course'),
('MAT1245', 'Calculus 1', 'Исчисление 1', 5, 'C', 'Exam', 'course'),
('LAN1194-LAN1199', 'Foreign language (English level A0-C1)', 'Иностранный язык (уровень английского A0-C1)', 5, 'G', 'Exam', 'course'),
('HUM1101', 'History of Kazakhstan', 'История Казахстана', 5, 'G', 'State exam', 'course'),
('MATH1203', 'Linear Algebra for engineers', 'Линейная алгебра для инженеров', 5, 'C', 'Exam', 'course'),
('INFT1101', 'Information and Communication Technologies', 'Информационно-коммуникационные технологии', 5, 'G', 'Exam', 'course'),
('CSCI1204', 'Programming Principles 2', 'Принципы программирования 2', 6, 'C', 'Exam', 'course'),
('MAT1246', 'Calculus 2', 'Исчисление 2', 5, 'C', 'Exam', 'course'),
('HUM1141', 'Module of socio-political knowledge (political science, sociology, cultural studies, psychology)', 'Модуль социально-политических знаний (политология, социология, культурология, психология)', 8, 'G', 'Exam', 'course'),
('CSCI1102', 'Discrete structures', 'Дискретные структуры', 5, 'C', 'Exam', 'course'),
('STAT2201', 'Statistics', 'Статистика', 5, 'C', 'Exam', 'course'),
('CSCI2104', 'Databases', 'Базы данных', 5, 'C', 'Exam', 'course'),
('CSCI2105', 'Algorithms and Data Structures', 'Алгоритмы и структуры данных', 5, 'C', 'Exam', 'course'),
('CSCI3115', 'Computer Architecture', 'Архитектура компьютерных систем', 5, 'S', 'Exam', 'course'),
('LAN1115-LAN1120,LAN1174-LAN1176', 'Kazakh (Russian) language (A0-C2)', 'Казахский (Русский) язык (A0-C2)', 5, 'G', 'Exam', 'course'),
('PHE101', 'Physical education', 'Физическая культура', 4, 'G', 'Exam', 'course'),
('INFT2205', 'Web Development', 'Web разработка', 6, 'S', 'Exam', 'course'),
('INFT2102', 'IT infrastructure and Computer Networks', 'ИТ инфраструктура и компьютерные сети', 6, 'S', 'Exam', 'course'),
('CSCI2106', 'Object-Oriented Programming and Design', 'Объектно-ориентированное программирование и дизайн', 5, 'C', 'Exam', 'course'),
('HUM1203', 'Sustainable development and public safety', 'Устойчивое развитие и безопасность общества', 5, 'C', 'Exam', 'course'),
('PHE102', 'Physical education', 'Физическая культура', 4, 'G', 'Exam', 'course'),
('CSCI2208', 'Software Engineering', 'Инструментальные средства разработки программного обеспечения', 5, 'C', 'Exam', 'course'),
('INFT3106', 'Fundamentals of Business for Information Systems', 'Основы бизнеса для информационных систем', 5, 'C', 'Exam', 'course'),
('INFT3107', 'Basics of Information Systems', 'Основы информационных систем', 5, 'C', 'Exam', 'course'),
('INFT3105', 'Cyber Security Fundamentals', 'Основы кибербезопасности', 5, 'S', 'Exam', 'course'),
('HUM1102', 'Philosophy', 'Философия', 5, 'G', 'Exam', 'course'),
('INFT3210', 'Field Projects for Information Systems', 'Целевые проекты информационных систем', 5, 'S', 'Exam', 'course'),
('INFT2204', 'Introduction to Business Management', 'Введение в управление бизнесом', 5, 'C', 'Exam', 'course'),
('INFT3108', 'IT Project Management', 'Управление ИТ проектами', 5, 'S', 'Exam', 'course'),
('INFT4139', 'System Design', 'Архитектура систем', 5, 'C', 'Exam', 'course'),
('CSCI4102', 'Research Tools and Methods', 'Инструменты и методы исследований', 4, 'S', 'Exam', 'course'),
('PRA334', 'Industrial Internship', 'Производственная практика', 5, 'C', 'Report', 'internship'),
('PRA437', 'Pre-diploma Internship', 'Преддипломная практика', 8, 'S', 'Report', 'internship'),
('IA1504', 'Final attestation', 'Итоговая аттестация', 8, 'FA', 'Defense/Exam', 'attestation');

INSERT INTO program_disciplines (program_id, discipline_id, semester, component)
SELECT p.id, d.id, v.semester, v.component
FROM (VALUES
    ('CSCI1103', 1, 'UC'), ('MAT1245', 1, 'UC'), ('LAN1194-LAN1199', 1, 'RC'),
    ('HUM1101', 1, 'RC'), ('MATH1203', 1, 'UC'), ('INFT1101', 1, 'RC'),
    ('CSCI1204', 2, 'UC'), ('MAT1246', 2, 'UC'), ('LAN1194-LAN1199', 2, 'RC'),
    ('HUM1141', 2, 'RC'), ('CSCI1102', 2, 'UC'),
    ('STAT2201', 3, 'UC'), ('CSCI2104', 3, 'UC'), ('CSCI2105', 3, 'UC'),
    ('CSCI3115', 3, 'UC'), ('LAN1115-LAN1120,LAN1174-LAN1176', 3, 'RC'), ('PHE101', 3, 'RC'),
    ('INFT2205', 4, 'UC'), ('INFT2102', 4, 'UC'), ('CSCI2106', 4, 'UC'),
    ('HUM1203', 4, 'UC'), ('LAN1115-LAN1120,LAN1174-LAN1176', 4, 'RC'), ('PHE102', 4, 'RC'),
    ('CSCI2208', 5, 'UC'), ('INFT3106', 5, 'UC'), ('INFT3107', 5, 'UC'), ('INFT3105', 5, 'UC'),
    ('HUM1102', 6, 'RC'), ('INFT3210', 6, 'UC'), ('INFT2204', 6, 'UC'),
    ('INFT3108', 7, 'UC'), ('INFT4139', 7, 'UC'), ('CSCI4102', 7, 'UC'), ('PRA334', 7, NULL),
    ('PRA437', 8, NULL), ('IA1504', 8, NULL)
) AS v(code, semester, component)
JOIN disciplines d ON d.code = v.code
CROSS JOIN programs p
WHERE p.code = '6B06101';

INSERT INTO prerequisites (discipline_id, prerequisite_id)
SELECT d.id, pr.id
FROM (VALUES
    ('CSCI1204', 'CSCI1103'), ('MAT1246', 'MAT1245'),
    ('STAT2201', 'CSCI1102'), ('CSCI2104', 'CSCI1102'),
    ('CSCI2105', 'CSCI1103'), ('CSCI2105', 'CSCI1102'),
    ('INFT2205', 'CSCI2104'), ('INFT2102', 'CSCI3115'), ('CSCI2106', 'CSCI1204'),
    ('PHE102', 'PHE101'), ('INFT3105', 'INFT2102'), ('INFT3210', 'INFT3107'),
    ('INFT3108', 'INFT2204'), ('INFT4139', 'CSCI2208')
) AS v(code, prereq)
JOIN disciplines d  ON d.code  = v.code
JOIN disciplines pr ON pr.code = v.prereq;
