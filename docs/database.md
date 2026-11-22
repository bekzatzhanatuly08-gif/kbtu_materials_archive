# База данных

PostgreSQL (Supabase). Схема создаётся файлами из папки `db/` в таком порядке:

1. `db/01_catalog.sql` — школы, специальности, дисциплины, пререквизиты
2. `db/02_core.sql` — профили, материалы, файлы, ИИ-проверки, лайки, комментарии, жалобы

Для локальной проверки в обычном PostgreSQL перед ними запускается `db/tests/00_local_auth_stub.sql`, после них — `db/tests/01_core_tests.sql`.

## ER-диаграмма

```mermaid
erDiagram
  SCHOOLS ||--o{ PROGRAMS : has
  PROGRAMS ||--o{ PROGRAM_DISCIPLINES : includes
  DISCIPLINES ||--o{ PROGRAM_DISCIPLINES : "taught in"
  DISCIPLINES ||--o{ PREREQUISITES : requires
  PROGRAMS ||--o{ PROFILES : "studies in"
  DISCIPLINES ||--o{ MATERIALS : contains
  PROFILES ||--o{ MATERIALS : uploads
  MATERIALS ||--|{ MATERIAL_FILES : has
  MATERIALS ||--o{ AI_REVIEWS : "checked by"
  PROFILES ||--o{ LIKES : gives
  MATERIALS ||--o{ LIKES : receives
  PROFILES ||--o{ COMMENTS : writes
  MATERIALS ||--o{ COMMENTS : has
  COMMENTS |o--o{ COMMENTS : "reply to"
  PROFILES ||--o{ REPORTS : files
  MATERIALS |o--o{ REPORTS : target
  COMMENTS |o--o{ REPORTS : target

  SCHOOLS {
    int id PK
    string code UK
    string name_en
    string name_ru
  }
  PROGRAMS {
    int id PK
    int school_id FK
    string code UK
    string name_en
    string name_ru
    string intake_year
    bool is_active
  }
  DISCIPLINES {
    int id PK
    string code UK
    string name_en
    string name_ru
    string name_kk
    smallint credits
    string cycle
    string control_form
    string kind
  }
  PROGRAM_DISCIPLINES {
    int program_id PK
    int discipline_id PK
    smallint semester PK
    string component
  }
  PREREQUISITES {
    int discipline_id PK
    int prerequisite_id PK
  }
  PROFILES {
    uuid id PK
    string email UK
    string full_name
    int program_id FK
    smallint year_of_study
    string role
    timestamptz created_at
  }
  MATERIALS {
    int id PK
    int discipline_id FK
    uuid author_id FK
    string title
    text description
    string material_type
    string language
    string academic_year
    string status
    bool is_verified
    uuid verified_by FK
    timestamptz created_at
    timestamptz updated_at
  }
  MATERIAL_FILES {
    int id PK
    int material_id FK
    text storage_path UK
    string file_name
    string mime_type
    bigint size_bytes
    timestamptz uploaded_at
  }
  AI_REVIEWS {
    int id PK
    int material_id FK
    string model
    string verdict
    numeric relevance_score
    smallint quality_score
    text summary
    text issues
    text_array tags
    timestamptz created_at
  }
  LIKES {
    uuid user_id PK
    int material_id PK
    timestamptz created_at
  }
  COMMENTS {
    int id PK
    int material_id FK
    uuid author_id FK
    int parent_id FK
    text body
    bool is_deleted
    timestamptz created_at
    timestamptz edited_at
  }
  REPORTS {
    int id PK
    uuid reporter_id FK
    int material_id FK
    int comment_id FK
    string reason
    text details
    string status
    uuid resolved_by FK
    timestamptz resolved_at
    timestamptz created_at
  }
```

## Ключевые правила

| Правило | Где задано |
|---|---|
| Регистрация только с почтой `@kbtu.kz` | `profiles.email` CHECK |
| Один лайк на материал от одного студента | `likes` PRIMARY KEY (user_id, material_id) |
| Жалоба — ровно на материал или ровно на комментарий | `reports` CHECK |
| У закрытой жалобы обязательно есть дата решения | `reports` CHECK |
| Значок «проверено» только с указанием модератора | `materials` CHECK |
| Файл не больше 20 МБ | `material_files.size_bytes` CHECK |
| Удаление материала удаляет его файлы, лайки, комментарии, проверки | ON DELETE CASCADE |
| Удаление аккаунта сохраняет материалы без автора | ON DELETE SET NULL |

## Представления

- `material_cards` — карточка опубликованного материала: предмет, автор, число лайков и комментариев, последний вердикт ИИ.
