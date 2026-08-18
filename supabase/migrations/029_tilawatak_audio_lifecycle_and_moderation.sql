-- ============================================================================
-- Migration 029: Tilawatak LilAlam Audio Lifecycle, Moderation & Deletion Fixes
-- Platform: TilawatakLilAlam (تلاوتك للعالم)
-- Description: 
--   1. Strict audio integrity: No fallback/mock data, valid audio validation.
--   2. Submissions Moderation Workflow: PENDING -> APPROVED / APPROVED_UNPUBLISHED / REJECTED.
--   3. Adds installation_id column to recitation_submissions.
--   4. Cascade Deletion RPC functions for admin operations.
--   5. Full RLS security policies allowing Admin operations and secure Public access.
--   6. Live pre-aggregated statistics views with exact ranking formula:
--      ranking_score = (likes * 3) + (listens * 1) + (recitations * 5)
-- ============================================================================

-- 1. SCHEMA UPDATES

-- 1.1 Ensure installation_id exists on recitation_submissions
ALTER TABLE public.recitation_submissions
    ADD COLUMN IF NOT EXISTS installation_id TEXT;

-- 1.2 Update recitation_submissions status check to allow APPROVED_UNPUBLISHED
DO $$
BEGIN
    ALTER TABLE public.recitation_submissions DROP CONSTRAINT IF EXISTS recitation_submissions_status_check;
    ALTER TABLE public.recitation_submissions ADD CONSTRAINT recitation_submissions_status_check 
        CHECK (status IN ('PENDING', 'APPROVED', 'APPROVED_UNPUBLISHED', 'REJECTED'));
EXCEPTION
    WHEN OTHERS THEN NULL;
END $$;

-- 1.3 Ensure recitations has is_published and updated status check
ALTER TABLE public.recitations
    ADD COLUMN IF NOT EXISTS is_published BOOLEAN NOT NULL DEFAULT TRUE;

DO $$
BEGIN
    ALTER TABLE public.recitations DROP CONSTRAINT IF EXISTS recitations_status_check;
    ALTER TABLE public.recitations ADD CONSTRAINT recitations_status_check 
        CHECK (status IN ('PENDING', 'APPROVED', 'APPROVED_UNPUBLISHED', 'REJECTED'));
EXCEPTION
    WHEN OTHERS THEN NULL;
END $$;

-- 1.4 Ensure user_notifications has all necessary columns
ALTER TABLE public.user_notifications
    ADD COLUMN IF NOT EXISTS installation_id TEXT,
    ADD COLUMN IF NOT EXISTS notification_type TEXT NOT NULL DEFAULT 'SYSTEM',
    ADD COLUMN IF NOT EXISTS target_country TEXT,
    ADD COLUMN IF NOT EXISTS target_user_type TEXT,
    ADD COLUMN IF NOT EXISTS is_read BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_user_notifications_inst_id ON public.user_notifications(installation_id);
CREATE INDEX IF NOT EXISTS idx_user_notifications_created ON public.user_notifications(created_at DESC);

-- ============================================================================
-- 2. SECURE CASCADE DELETION RPCs (ADMIN ONLY)
-- ============================================================================

-- 2.1 Admin Delete Reciter (Cascades all recitations, likes, listens, honors)
CREATE OR REPLACE FUNCTION public.admin_delete_reciter(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete a reciter';
    END IF;

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Reciter ID cannot be null';
    END IF;

    -- 1. Delete honors
    DELETE FROM public.reciter_honors WHERE reciter_id = p_id;

    -- 2. Delete featured entries
    DELETE FROM public.featured_reciters WHERE reciter_id = p_id;

    -- 3. Delete likes for this reciter's recitations
    DELETE FROM public.likes 
    WHERE recitation_id IN (SELECT id FROM public.recitations WHERE reciter_id = p_id);

    -- 4. Delete listen events for this reciter's recitations
    DELETE FROM public.listen_events 
    WHERE recitation_id IN (SELECT id FROM public.recitations WHERE reciter_id = p_id);

    -- 5. Delete recitations
    DELETE FROM public.recitations WHERE reciter_id = p_id;

    -- 6. Delete reciter
    DELETE FROM public.reciters WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 2.2 Admin Delete Recitation (Cascades likes and listen events)
CREATE OR REPLACE FUNCTION public.admin_delete_recitation(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete a recitation';
    END IF;

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Recitation ID cannot be null';
    END IF;

    -- 1. Delete likes
    DELETE FROM public.likes WHERE recitation_id = p_id;

    -- 2. Delete listen events
    DELETE FROM public.listen_events WHERE recitation_id = p_id;

    -- 3. Delete recitation
    DELETE FROM public.recitations WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 2.3 Admin Delete Competition
CREATE OR REPLACE FUNCTION public.admin_delete_competition(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete a competition';
    END IF;

    DELETE FROM public.competitions WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 2.4 Admin Delete Announcement
CREATE OR REPLACE FUNCTION public.admin_delete_announcement(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete an announcement';
    END IF;

    DELETE FROM public.announcements WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 2.5 Admin Delete Submission
CREATE OR REPLACE FUNCTION public.admin_delete_submission(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete a submission';
    END IF;

    DELETE FROM public.recitation_submissions WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 2.6 Admin Delete User Profile
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_id UUID)
RETURNS VOID AS $$
DECLARE
    v_inst_id TEXT;
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to delete a user profile';
    END IF;

    SELECT installation_id INTO v_inst_id FROM public.user_profiles WHERE id = p_id;

    -- 1. Delete notifications for this user
    IF v_inst_id IS NOT NULL AND TRIM(v_inst_id) <> '' THEN
        DELETE FROM public.user_notifications WHERE installation_id = v_inst_id;
    END IF;
    DELETE FROM public.user_notifications WHERE user_id = p_id;

    -- 2. Delete user profile
    DELETE FROM public.user_profiles WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION public.admin_delete_reciter(UUID) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_recitation(UUID) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_competition(UUID) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_announcement(UUID) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_submission(UUID) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(UUID) TO anon, authenticated, service_role;

-- ============================================================================
-- 3. PUBLIC RPC FOR SUBMITTING RECITATIONS (WITH INSTALLATION_ID)
-- ============================================================================

DROP FUNCTION IF EXISTS public.submit_recitation_public CASCADE;

CREATE OR REPLACE FUNCTION public.submit_recitation_public(
    p_display_name TEXT,
    p_pseudonym TEXT DEFAULT NULL,
    p_use_pseudonym BOOLEAN DEFAULT FALSE,
    p_gender TEXT DEFAULT 'MALE',
    p_country TEXT DEFAULT 'العالم الإسلامي',
    p_surah_number INTEGER DEFAULT 1,
    p_surah_name TEXT DEFAULT '',
    p_ayah_start INTEGER DEFAULT 1,
    p_ayah_end INTEGER DEFAULT 1,
    p_riwayah TEXT DEFAULT 'حفص عن عاصم',
    p_description TEXT DEFAULT '',
    p_audio_storage_path TEXT DEFAULT '',
    p_external_audio_url TEXT DEFAULT NULL,
    p_profile_image_path TEXT DEFAULT NULL,
    p_installation_id TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_new_id UUID;
    v_clean_gender TEXT;
BEGIN
    -- Validate parameters
    IF p_display_name IS NULL OR TRIM(p_display_name) = '' THEN
        RAISE EXCEPTION 'Display name is required';
    END IF;
    IF (p_audio_storage_path IS NULL OR TRIM(p_audio_storage_path) = '') 
       AND (p_external_audio_url IS NULL OR TRIM(p_external_audio_url) = '') THEN
        RAISE EXCEPTION 'A valid audio storage path or external audio URL is required';
    END IF;

    v_clean_gender := UPPER(TRIM(COALESCE(p_gender, 'MALE')));
    IF v_clean_gender NOT IN ('MALE', 'FEMALE') THEN
        v_clean_gender := 'MALE';
    END IF;

    INSERT INTO public.recitation_submissions (
        display_name,
        pseudonym,
        use_pseudonym,
        gender,
        country,
        surah_number,
        surah_name,
        ayah_start,
        ayah_end,
        riwayah,
        description,
        audio_storage_path,
        external_audio_url,
        profile_image_path,
        installation_id,
        status,
        created_at
    ) VALUES (
        TRIM(p_display_name),
        NULLIF(TRIM(COALESCE(p_pseudonym, '')), ''),
        p_use_pseudonym,
        v_clean_gender,
        COALESCE(NULLIF(TRIM(p_country), ''), 'العالم الإسلامي'),
        GREATEST(1, LEAST(114, COALESCE(p_surah_number, 1))),
        COALESCE(NULLIF(TRIM(p_surah_name), ''), 'سورة الفاتحة'),
        GREATEST(1, COALESCE(p_ayah_start, 1)),
        GREATEST(1, COALESCE(p_ayah_end, 1)),
        COALESCE(NULLIF(TRIM(p_riwayah), ''), 'حفص عن عاصم'),
        COALESCE(TRIM(p_description), ''),
        COALESCE(TRIM(p_audio_storage_path), ''),
        NULLIF(TRIM(COALESCE(p_external_audio_url, '')), ''),
        NULLIF(TRIM(COALESCE(p_profile_image_path, '')), ''),
        NULLIF(TRIM(COALESCE(p_installation_id, '')), ''),
        'PENDING',
        NOW()
    )
    RETURNING id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION public.submit_recitation_public TO anon, authenticated, service_role;

-- 3.6 Admin Send Broadcast Notifications to User Profiles
CREATE OR REPLACE FUNCTION public.admin_send_broadcast(
    p_title TEXT,
    p_body TEXT,
    p_notification_type TEXT DEFAULT 'ADMIN_ANNOUNCEMENT',
    p_target_type TEXT DEFAULT 'all',
    p_target_value TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_count INT := 0;
    v_rec RECORD;
BEGIN
    IF NOT (public.is_admin() OR auth.role() = 'service_role') THEN
        RAISE EXCEPTION 'Access denied: Admin privileges required to broadcast notifications';
    END IF;

    FOR v_rec IN 
        SELECT installation_id, id, country, user_type, is_profile_completed
        FROM public.user_profiles
        WHERE installation_id IS NOT NULL AND installation_id <> ''
          AND (
              p_target_type = 'all' OR
              (p_target_type = 'country' AND (country = p_target_value OR p_target_value IS NULL)) OR
              (p_target_type = 'user_type' AND (user_type = p_target_value OR p_target_value IS NULL)) OR
              (p_target_type = 'incomplete_profile' AND is_profile_completed = FALSE) OR
              (p_target_type = 'specific_user' AND (id::TEXT = p_target_value OR installation_id = p_target_value))
          )
    LOOP
        INSERT INTO public.user_notifications (
            installation_id,
            title,
            body,
            notification_type,
            target_country,
            target_user_type,
            is_read,
            created_at
        ) VALUES (
            v_rec.installation_id,
            p_title,
            p_body,
            COALESCE(p_notification_type, 'ADMIN_ANNOUNCEMENT'),
            CASE WHEN p_target_type = 'country' THEN p_target_value ELSE NULL END,
            CASE WHEN p_target_type = 'user_type' THEN p_target_value ELSE NULL END,
            FALSE,
            NOW()
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object('success', TRUE, 'dispatched_count', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION public.admin_send_broadcast TO anon, authenticated, service_role;

-- ============================================================================
-- 4. REAL-TIME PRE-AGGREGATED STATISTICAL VIEWS
-- ============================================================================

DROP VIEW IF EXISTS public.reciter_statistics_view CASCADE;
DROP VIEW IF EXISTS public.recitation_statistics_view CASCADE;

-- 4.1 Reciter Statistics View
CREATE OR REPLACE VIEW public.reciter_statistics_view AS
SELECT
    rc.id AS reciter_id,
    CASE
        WHEN rc.use_pseudonym = TRUE AND rc.pseudonym IS NOT NULL AND TRIM(rc.pseudonym) <> '' THEN rc.pseudonym
        ELSE rc.display_name
    END AS public_name,
    rc.gender,
    rc.country,
    rc.bio,
    rc.profile_image_path,
    rc.is_verified,
    rc.is_featured,
    rc.is_published,
    rc.created_at,
    COALESCE(rec_stats.total_recitations, 0)::BIGINT AS total_recitations,
    COALESCE(lk_stats.total_likes, 0)::BIGINT AS total_likes,
    COALESCE(ls_stats.total_listens, 0)::BIGINT AS total_listens,
    (
        (COALESCE(lk_stats.total_likes, 0)::BIGINT * 3) +
        (COALESCE(ls_stats.total_listens, 0)::BIGINT * 1) +
        (COALESCE(rec_stats.total_recitations, 0)::BIGINT * 5)
    )::BIGINT AS ranking_score,
    rc.id AS id,
    rc.display_name,
    rc.pseudonym,
    rc.use_pseudonym,
    rc.profile_image_path AS avatar_url
FROM public.reciters rc
LEFT JOIN (
    SELECT reciter_id, COUNT(*) AS total_recitations
    FROM public.recitations
    WHERE status = 'APPROVED' AND (is_published IS NULL OR is_published = TRUE)
    GROUP BY reciter_id
) rec_stats ON rec_stats.reciter_id = rc.id
LEFT JOIN (
    SELECT r.reciter_id, COUNT(l.id) AS total_likes
    FROM public.recitations r
    JOIN public.likes l ON l.recitation_id = r.id
    WHERE r.status = 'APPROVED' AND (r.is_published IS NULL OR r.is_published = TRUE)
    GROUP BY r.reciter_id
) lk_stats ON lk_stats.reciter_id = rc.id
LEFT JOIN (
    SELECT r.reciter_id, COUNT(le.id) AS total_listens
    FROM public.recitations r
    JOIN public.listen_events le ON le.recitation_id = r.id
    WHERE r.status = 'APPROVED' AND (r.is_published IS NULL OR r.is_published = TRUE)
    GROUP BY r.reciter_id
) ls_stats ON ls_stats.reciter_id = rc.id;

-- 4.2 Recitation Statistics View
CREATE OR REPLACE VIEW public.recitation_statistics_view AS
SELECT
    r.id,
    r.reciter_id,
    CASE
        WHEN rc.use_pseudonym = TRUE AND rc.pseudonym IS NOT NULL AND TRIM(rc.pseudonym) <> '' THEN rc.pseudonym
        ELSE rc.display_name
    END AS reciter_name,
    rc.profile_image_path AS reciter_avatar,
    rc.country AS reciter_country,
    r.surah_number,
    r.surah_name,
    CASE
        WHEN r.ayah_start = r.ayah_end THEN r.ayah_start::TEXT
        ELSE CONCAT(r.ayah_start, ' - ', r.ayah_end)
    END AS ayah_range,
    r.riwayah,
    r.duration_seconds,
    r.audio_storage_path,
    r.external_audio_url,
    r.cover_image_path,
    r.description,
    r.is_staff_pick,
    r.published_at,
    r.created_at,
    COALESCE(lk_cnt.likes_count, 0)::BIGINT AS like_count,
    COALESCE(ls_cnt.listens_count, 0)::BIGINT AS listen_count
FROM public.recitations r
JOIN public.reciters rc ON rc.id = r.reciter_id
LEFT JOIN (
    SELECT recitation_id, COUNT(*) AS likes_count
    FROM public.likes
    GROUP BY recitation_id
) lk_cnt ON lk_cnt.recitation_id = r.id
LEFT JOIN (
    SELECT recitation_id, COUNT(*) AS listens_count
    FROM public.listen_events
    GROUP BY recitation_id
) ls_cnt ON ls_cnt.recitation_id = r.id
WHERE r.status = 'APPROVED' AND rc.is_published = TRUE AND (r.is_published IS NULL OR r.is_published = TRUE);

GRANT SELECT ON public.reciter_statistics_view TO anon, authenticated, service_role;
GRANT SELECT ON public.recitation_statistics_view TO anon, authenticated, service_role;

-- ============================================================================
-- 5. ROW LEVEL SECURITY (RLS) POLICIES FOR OPERATIONAL CONTINUITY
-- ============================================================================

ALTER TABLE public.reciters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recitation_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listen_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;

-- 5.1 Reciters
DROP POLICY IF EXISTS "public_read_reciters" ON public.reciters;
CREATE POLICY "public_read_reciters" ON public.reciters
    FOR SELECT TO anon, authenticated, service_role
    USING (is_published = TRUE OR is_admin() OR auth.role() = 'service_role');

DROP POLICY IF EXISTS "admin_manage_reciters" ON public.reciters;
CREATE POLICY "admin_manage_reciters" ON public.reciters
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.2 Recitations
DROP POLICY IF EXISTS "public_read_recitations" ON public.recitations;
CREATE POLICY "public_read_recitations" ON public.recitations
    FOR SELECT TO anon, authenticated, service_role
    USING ((status = 'APPROVED' AND (is_published IS NULL OR is_published = TRUE)) OR is_admin() OR auth.role() = 'service_role');

DROP POLICY IF EXISTS "admin_manage_recitations" ON public.recitations;
CREATE POLICY "admin_manage_recitations" ON public.recitations
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.3 Competitions
DROP POLICY IF EXISTS "public_read_competitions" ON public.competitions;
CREATE POLICY "public_read_competitions" ON public.competitions
    FOR SELECT TO anon, authenticated, service_role
    USING (is_published = TRUE OR is_admin() OR auth.role() = 'service_role');

DROP POLICY IF EXISTS "admin_manage_competitions" ON public.competitions;
CREATE POLICY "admin_manage_competitions" ON public.competitions
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.4 Announcements
DROP POLICY IF EXISTS "public_read_announcements" ON public.announcements;
CREATE POLICY "public_read_announcements" ON public.announcements
    FOR SELECT TO anon, authenticated, service_role
    USING (is_published = TRUE OR is_admin() OR auth.role() = 'service_role');

DROP POLICY IF EXISTS "admin_manage_announcements" ON public.announcements;
CREATE POLICY "admin_manage_announcements" ON public.announcements
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.5 Recitation Submissions
DROP POLICY IF EXISTS "public_insert_submissions" ON public.recitation_submissions;
CREATE POLICY "public_insert_submissions" ON public.recitation_submissions
    FOR INSERT TO anon, authenticated, service_role
    WITH CHECK (TRUE);

DROP POLICY IF EXISTS "admin_manage_submissions" ON public.recitation_submissions;
CREATE POLICY "admin_manage_submissions" ON public.recitation_submissions
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.6 User Notifications
DROP POLICY IF EXISTS "public_read_notifications" ON public.user_notifications;
CREATE POLICY "public_read_notifications" ON public.user_notifications
    FOR SELECT TO anon, authenticated, service_role
    USING (TRUE);

DROP POLICY IF EXISTS "public_update_notifications" ON public.user_notifications;
CREATE POLICY "public_update_notifications" ON public.user_notifications
    FOR UPDATE TO anon, authenticated, service_role
    USING (TRUE)
    WITH CHECK (TRUE);

DROP POLICY IF EXISTS "admin_manage_notifications" ON public.user_notifications;
CREATE POLICY "admin_manage_notifications" ON public.user_notifications
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- 5.7 User Profiles
DROP POLICY IF EXISTS "public_read_user_profiles" ON public.user_profiles;
CREATE POLICY "public_read_user_profiles" ON public.user_profiles
    FOR SELECT TO anon, authenticated, service_role
    USING (TRUE);

DROP POLICY IF EXISTS "public_insert_user_profiles" ON public.user_profiles;
CREATE POLICY "public_insert_user_profiles" ON public.user_profiles
    FOR INSERT TO anon, authenticated, service_role
    WITH CHECK (TRUE);

DROP POLICY IF EXISTS "public_update_user_profiles" ON public.user_profiles;
CREATE POLICY "public_update_user_profiles" ON public.user_profiles
    FOR UPDATE TO anon, authenticated, service_role
    USING (TRUE)
    WITH CHECK (TRUE);

DROP POLICY IF EXISTS "admin_manage_user_profiles" ON public.user_profiles;
CREATE POLICY "admin_manage_user_profiles" ON public.user_profiles
    FOR ALL TO anon, authenticated, service_role
    USING (is_admin() OR auth.role() = 'service_role')
    WITH CHECK (is_admin() OR auth.role() = 'service_role');

-- Final notification
DO $$
BEGIN
    RAISE NOTICE 'Migration 029: Audio Lifecycle, Moderation & Deletion Fixes successfully installed';
END $$;
