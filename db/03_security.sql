-- KBTU Materials Archive — security: signup rules, privileges, Row Level Security, moderation, storage
-- Requires 01_catalog.sql and 02_core.sql. Written for Supabase. Rules: docs/access-rules.md
--
-- Three layers of protection:
--   1. Column privileges (GRANT): WHICH columns a role may read or write at all
--   2. Row Level Security (POLICY): WHICH rows a user may see or change
--   3. Triggers and functions: business rules (status workflow, 15-minute edit window, moderation)
--
-- The whole file runs as one transaction: if anything fails, nothing is applied.

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;


-- =====================================================================
-- 1. HELPER FUNCTIONS
-- =====================================================================

CREATE OR REPLACE FUNCTION private.is_moderator()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role IN ('moderator', 'admin')
    );
$$;


-- =====================================================================
-- 2. DEFAULTS AND EXTRA CONSTRAINTS
-- =====================================================================

ALTER TABLE public.materials ALTER COLUMN author_id   SET DEFAULT auth.uid();
ALTER TABLE public.likes     ALTER COLUMN user_id     SET DEFAULT auth.uid();
ALTER TABLE public.comments  ALTER COLUMN author_id   SET DEFAULT auth.uid();
ALTER TABLE public.reports   ALTER COLUMN reporter_id SET DEFAULT auth.uid();

ALTER TABLE public.material_files ADD CONSTRAINT material_files_mime_check CHECK (mime_type IN (
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain',
    'image/jpeg',
    'image/png',
    'image/webp'
));

CREATE UNIQUE INDEX reports_one_open_per_material
    ON public.reports (reporter_id, material_id)
    WHERE status = 'open' AND material_id IS NOT NULL;

CREATE UNIQUE INDEX reports_one_open_per_comment
    ON public.reports (reporter_id, comment_id)
    WHERE status = 'open' AND comment_id IS NOT NULL;


-- =====================================================================
-- 3. SIGNUP: only @kbtu.kz, profile is created automatically
-- =====================================================================

CREATE OR REPLACE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.email IS NULL OR NEW.email !~* '^[^@\s]+@kbtu\.kz$' THEN
        RAISE EXCEPTION 'Only @kbtu.kz email addresses are allowed' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO public.profiles (id, email, full_name)
    VALUES (
        NEW.id,
        lower(NEW.email),
        left(coalesce(nullif(trim(NEW.raw_user_meta_data ->> 'full_name'), ''), split_part(NEW.email, '@', 1)), 150)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION private.handle_new_user();

CREATE OR REPLACE FUNCTION private.handle_user_email_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.email IS NULL OR NEW.email !~* '^[^@\s]+@kbtu\.kz$' THEN
        RAISE EXCEPTION 'Only @kbtu.kz email addresses are allowed' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE public.profiles SET email = lower(NEW.email) WHERE id = NEW.id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_email_changed
    AFTER UPDATE OF email ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email)
    EXECUTE FUNCTION private.handle_user_email_change();


-- =====================================================================
-- 4. MATERIALS: editing sends the material back to AI review
-- =====================================================================

CREATE OR REPLACE FUNCTION private.materials_before_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF (NEW.discipline_id, NEW.title, NEW.description, NEW.material_type, NEW.language, NEW.academic_year)
       IS DISTINCT FROM
       (OLD.discipline_id, OLD.title, OLD.description, OLD.material_type, OLD.language, OLD.academic_year)
    THEN
        NEW.updated_at := now();

        -- A student edit resets the review. A material hidden by a moderator stays hidden.
        IF current_user = 'authenticated' AND OLD.status <> 'hidden' THEN
            NEW.status      := 'pending';
            NEW.is_verified := FALSE;
            NEW.verified_by := NULL;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER materials_before_update
    BEFORE UPDATE ON public.materials
    FOR EACH ROW EXECUTE FUNCTION private.materials_before_update();

-- Adding or removing a file is also an edit: the material goes back to review.
CREATE OR REPLACE FUNCTION private.material_files_after_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        UPDATE public.materials
        SET status = 'pending', is_verified = FALSE, verified_by = NULL, updated_at = now()
        WHERE id = coalesce(NEW.material_id, OLD.material_id)
          AND status IN ('published', 'rejected');
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER material_files_after_change
    AFTER INSERT OR DELETE ON public.material_files
    FOR EACH ROW EXECUTE FUNCTION private.material_files_after_change();


-- =====================================================================
-- 5. COMMENTS: replies stay in one thread, 15-minute edit window, soft delete
-- =====================================================================

CREATE OR REPLACE FUNCTION private.comments_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_parent_material_id INT;
BEGIN
    IF NEW.parent_id IS NOT NULL THEN
        SELECT material_id INTO v_parent_material_id FROM public.comments WHERE id = NEW.parent_id;
        IF v_parent_material_id IS DISTINCT FROM NEW.material_id THEN
            RAISE EXCEPTION 'A reply must belong to the same material as its parent comment';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER comments_before_insert
    BEFORE INSERT ON public.comments
    FOR EACH ROW EXECUTE FUNCTION private.comments_before_insert();

CREATE OR REPLACE FUNCTION private.comments_before_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    IF OLD.is_deleted THEN
        RAISE EXCEPTION 'A deleted comment cannot be changed or restored';
    END IF;

    IF NEW.is_deleted THEN
        NEW.body := '[удалено]';
        RETURN NEW;
    END IF;

    IF NEW.body IS DISTINCT FROM OLD.body THEN
        IF OLD.author_id IS DISTINCT FROM auth.uid() THEN
            RAISE EXCEPTION 'Only the author can edit a comment';
        END IF;
        IF now() > OLD.created_at + INTERVAL '15 minutes' THEN
            RAISE EXCEPTION 'A comment can only be edited within 15 minutes of posting';
        END IF;
        NEW.edited_at := now();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER comments_before_update
    BEFORE UPDATE ON public.comments
    FOR EACH ROW EXECUTE FUNCTION private.comments_before_update();


-- =====================================================================
-- 6. MODERATION FUNCTIONS (called from the site as RPC)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.moderate_material(p_material_id INT, p_action TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT private.is_moderator() THEN
        RAISE EXCEPTION 'Only moderators can moderate materials' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_action = 'publish' THEN
        UPDATE public.materials SET status = 'published' WHERE id = p_material_id;
    ELSIF p_action = 'reject' THEN
        UPDATE public.materials SET status = 'rejected', is_verified = FALSE, verified_by = NULL WHERE id = p_material_id;
    ELSIF p_action = 'hide' THEN
        UPDATE public.materials SET status = 'hidden' WHERE id = p_material_id;
    ELSIF p_action = 'verify' THEN
        UPDATE public.materials SET is_verified = TRUE, verified_by = auth.uid()
        WHERE id = p_material_id AND status = 'published';
    ELSIF p_action = 'unverify' THEN
        UPDATE public.materials SET is_verified = FALSE, verified_by = NULL WHERE id = p_material_id;
    ELSE
        RAISE EXCEPTION 'Unknown action: %', p_action;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material % not found (or not published, for verify)', p_material_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_report(p_report_id INT, p_status TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT private.is_moderator() THEN
        RAISE EXCEPTION 'Only moderators can resolve reports' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_status IS NULL OR p_status NOT IN ('resolved', 'dismissed') THEN
        RAISE EXCEPTION 'Status must be resolved or dismissed';
    END IF;

    UPDATE public.reports
    SET status = p_status, resolved_by = auth.uid(), resolved_at = now()
    WHERE id = p_report_id AND status = 'open';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Open report % not found', p_report_id;
    END IF;
END;
$$;


-- =====================================================================
-- 7. ROW LEVEL SECURITY
-- =====================================================================

ALTER TABLE public.schools             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disciplines         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.program_disciplines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prerequisites       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.materials           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_files      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_reviews          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports             ENABLE ROW LEVEL SECURITY;

-- Catalog: everyone, including guests, can read
CREATE POLICY "Catalog is public" ON public.schools             FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Catalog is public" ON public.programs            FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Catalog is public" ON public.disciplines         FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Catalog is public" ON public.program_disciplines FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Catalog is public" ON public.prerequisites       FOR SELECT TO anon, authenticated USING (true);

-- Profiles
CREATE POLICY "Students can see profiles" ON public.profiles
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "Students can update own profile" ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = (SELECT auth.uid()))
    WITH CHECK (id = (SELECT auth.uid()));

-- Materials
CREATE POLICY "Published, own, or any for moderators" ON public.materials
    FOR SELECT TO authenticated
    USING (
        status = 'published'
        OR author_id = (SELECT auth.uid())
        OR (SELECT private.is_moderator())
    );

CREATE POLICY "Students create own pending materials" ON public.materials
    FOR INSERT TO authenticated
    WITH CHECK (author_id = (SELECT auth.uid()) AND status = 'pending' AND NOT is_verified);

CREATE POLICY "Authors edit own materials" ON public.materials
    FOR UPDATE TO authenticated
    USING (author_id = (SELECT auth.uid()))
    WITH CHECK (author_id = (SELECT auth.uid()));

CREATE POLICY "Authors delete own materials" ON public.materials
    FOR DELETE TO authenticated
    USING (author_id = (SELECT auth.uid()));

-- Material files: visible together with their material
CREATE POLICY "Files of visible materials" ON public.material_files
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.materials m WHERE m.id = material_files.material_id));

CREATE POLICY "Authors add files to own materials" ON public.material_files
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.materials m
            WHERE m.id = material_files.material_id AND m.author_id = (SELECT auth.uid())
        )
        AND storage_path LIKE (SELECT auth.uid())::text || '/' || material_files.material_id::text || '/%'
    );

CREATE POLICY "Authors delete files of own materials" ON public.material_files
    FOR DELETE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.materials m
            WHERE m.id = material_files.material_id AND m.author_id = (SELECT auth.uid())
        )
    );

-- AI reviews: read-only for students, written only by the server
CREATE POLICY "Reviews of visible materials" ON public.ai_reviews
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.materials m WHERE m.id = ai_reviews.material_id));

-- Likes: everyone sees who liked; like only as yourself and only published materials
CREATE POLICY "Likes of visible materials" ON public.likes
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.materials m WHERE m.id = likes.material_id));

CREATE POLICY "Like published materials as yourself" ON public.likes
    FOR INSERT TO authenticated
    WITH CHECK (
        user_id = (SELECT auth.uid())
        AND EXISTS (SELECT 1 FROM public.materials m WHERE m.id = likes.material_id AND m.status = 'published')
    );

CREATE POLICY "Remove own likes" ON public.likes
    FOR DELETE TO authenticated
    USING (user_id = (SELECT auth.uid()));

-- Comments
CREATE POLICY "Comments of visible materials" ON public.comments
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.materials m WHERE m.id = comments.material_id));

CREATE POLICY "Comment published materials as yourself" ON public.comments
    FOR INSERT TO authenticated
    WITH CHECK (
        author_id = (SELECT auth.uid())
        AND EXISTS (SELECT 1 FROM public.materials m WHERE m.id = comments.material_id AND m.status = 'published')
    );

CREATE POLICY "Authors change own comments" ON public.comments
    FOR UPDATE TO authenticated
    USING (author_id = (SELECT auth.uid()))
    WITH CHECK (author_id = (SELECT auth.uid()));

CREATE POLICY "Moderators delete any comment" ON public.comments
    FOR UPDATE TO authenticated
    USING ((SELECT private.is_moderator()))
    WITH CHECK ((SELECT private.is_moderator()));

-- Reports
CREATE POLICY "Own reports, or all for moderators" ON public.reports
    FOR SELECT TO authenticated
    USING (reporter_id = (SELECT auth.uid()) OR (SELECT private.is_moderator()));

CREATE POLICY "Report visible content as yourself" ON public.reports
    FOR INSERT TO authenticated
    WITH CHECK (
        reporter_id = (SELECT auth.uid())
        AND status = 'open'
        AND (material_id IS NULL OR EXISTS (SELECT 1 FROM public.materials m WHERE m.id = reports.material_id))
        AND (comment_id  IS NULL OR EXISTS (SELECT 1 FROM public.comments  c WHERE c.id = reports.comment_id))
    );

-- The view respects the RLS of the tables it reads from
ALTER VIEW public.material_cards SET (security_invoker = true);


-- =====================================================================
-- 8. PRIVILEGES: start from zero, then allow exactly what is needed
-- =====================================================================

REVOKE ALL ON ALL TABLES    IN SCHEMA public  FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public  FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;

GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_moderator() TO authenticated;

-- Catalog
GRANT SELECT ON public.schools, public.programs, public.disciplines,
                public.program_disciplines, public.prerequisites
    TO anon, authenticated;

-- Profiles: email is hidden from other students; role cannot be changed by the student
GRANT SELECT (id, full_name, program_id, year_of_study, role, created_at) ON public.profiles TO authenticated;
GRANT UPDATE (full_name, program_id, year_of_study) ON public.profiles TO authenticated;

-- Materials: status, verification and author are not writable by students
GRANT SELECT, DELETE ON public.materials TO authenticated;
GRANT INSERT (discipline_id, title, description, material_type, language, academic_year) ON public.materials TO authenticated;
GRANT UPDATE (discipline_id, title, description, material_type, language, academic_year) ON public.materials TO authenticated;

GRANT SELECT, DELETE ON public.material_files TO authenticated;
GRANT INSERT (material_id, storage_path, file_name, mime_type, size_bytes) ON public.material_files TO authenticated;

GRANT SELECT ON public.ai_reviews TO authenticated;

GRANT SELECT, DELETE ON public.likes TO authenticated;
GRANT INSERT (material_id) ON public.likes TO authenticated;

GRANT SELECT ON public.comments TO authenticated;
GRANT INSERT (material_id, parent_id, body) ON public.comments TO authenticated;
GRANT UPDATE (body, is_deleted) ON public.comments TO authenticated;

GRANT SELECT ON public.reports TO authenticated;
GRANT INSERT (material_id, comment_id, reason, details) ON public.reports TO authenticated;

GRANT SELECT ON public.material_cards TO authenticated;

GRANT USAGE ON SEQUENCE public.materials_id_seq, public.material_files_id_seq,
                        public.comments_id_seq, public.reports_id_seq
    TO authenticated;

GRANT EXECUTE ON FUNCTION public.moderate_material(INT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_report(INT, TEXT)    TO authenticated;

-- Server-side role (Edge Functions, AI review). Never used in the browser; bypasses RLS.
GRANT ALL ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;


-- =====================================================================
-- 9. FILE STORAGE
-- Path of every file: <author uuid>/<material id>/<file name>
-- =====================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'materials',
    'materials',
    FALSE,
    20971520,
    ARRAY[
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'text/plain',
        'image/jpeg',
        'image/png',
        'image/webp'
    ]
)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Authors upload to own material folders" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'materials'
        AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
        AND EXISTS (
            SELECT 1 FROM public.materials m
            WHERE m.id::text = (storage.foldername(name))[2]
              AND m.author_id = (SELECT auth.uid())
        )
    );

CREATE POLICY "Students read files of visible materials" ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'materials'
        AND EXISTS (SELECT 1 FROM public.material_files f WHERE f.storage_path = name)
    );

CREATE POLICY "Authors delete own files" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'materials'
        AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    );

COMMIT;
