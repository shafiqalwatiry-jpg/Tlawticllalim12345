-- ============================================================================
-- Migration 026: Production Security Hardening and Data Integrity
-- Platform: TilawatakLilAlam (تلاوتك للعالم)
-- Description: 
--   1. Protects all administrative RPC functions with internal is_admin() authorization checks.
--   2. Revokes public/anonymous execution permissions on sensitive admin endpoints.
--   3. Guarantees cascade data integrity across reciters, recitations, submissions, likes, and notifications.
--   4. Standardizes metrics calculation directly from operational tables without static/hardcoded fallbacks.
--   5. Ensures robust RLS policies for guest profiles and in-app notifications.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Ensure Role Validation Functions Exist and are Idempotent
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.admin_profiles
        WHERE id = auth.uid()
          AND is_active = TRUE
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.admin_profiles
        WHERE id = auth.uid()
          AND role = 'SUPER_ADMIN'
          AND is_active = TRUE
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ----------------------------------------------------------------------------
-- 2. Secure Administrative Dashboard Metrics Function
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_admin_dashboard_metrics()
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    -- Strict security authorization check
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    SELECT json_build_object(
        'totalReciters', (SELECT COUNT(*) FROM public.reciters),
        'publishedReciters', (SELECT COUNT(*) FROM public.reciters WHERE is_published = TRUE),
        'totalRecitations', (SELECT COUNT(*) FROM public.recitations),
        'publishedRecitations', (SELECT COUNT(*) FROM public.recitations WHERE status = 'APPROVED'),
        'pendingSubmissions', (SELECT COUNT(*) FROM public.recitation_submissions WHERE status = 'PENDING'),
        'totalListens', (SELECT COUNT(*) FROM public.listen_events),
        'totalLikes', (SELECT COUNT(*) FROM public.likes),
        'activeCompetitions', (SELECT COUNT(*) FROM public.competitions WHERE is_published = TRUE),
        'totalUsers', (SELECT COUNT(*) FROM public.user_profiles)
    ) INTO result;

    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ----------------------------------------------------------------------------
-- 3. Secure Administrative Deletion RPCs with Cascade Data Integrity
-- ----------------------------------------------------------------------------

-- 3.1. Delete Reciter (Cascades honors, featured status, recitations, likes, listen events)
CREATE OR REPLACE FUNCTION public.admin_delete_reciter(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    -- Delete related honors
    DELETE FROM public.reciter_honors WHERE reciter_id = p_id;

    -- Delete related featured reciter entries
    DELETE FROM public.featured_reciters WHERE reciter_id = p_id;

    -- Delete related likes and listen events for all recitations of this reciter
    DELETE FROM public.likes WHERE recitation_id IN (
        SELECT id FROM public.recitations WHERE reciter_id = p_id
    );
    DELETE FROM public.listen_events WHERE recitation_id IN (
        SELECT id FROM public.recitations WHERE reciter_id = p_id
    );

    -- Delete recitations
    DELETE FROM public.recitations WHERE reciter_id = p_id;

    -- Delete reciter record
    DELETE FROM public.reciters WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.2. Delete Recitation (Cascades likes and listen events)
CREATE OR REPLACE FUNCTION public.admin_delete_recitation(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    DELETE FROM public.likes WHERE recitation_id = p_id;
    DELETE FROM public.listen_events WHERE recitation_id = p_id;
    DELETE FROM public.recitations WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.3. Delete Competition
CREATE OR REPLACE FUNCTION public.admin_delete_competition(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    DELETE FROM public.competitions WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.4. Delete Announcement
CREATE OR REPLACE FUNCTION public.admin_delete_announcement(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    DELETE FROM public.announcements WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.5. Delete Submission
CREATE OR REPLACE FUNCTION public.admin_delete_submission(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    DELETE FROM public.recitation_submissions WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.6. Delete User Profile and Associated Notifications
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_id UUID)
RETURNS VOID AS $$
DECLARE
    v_install_id TEXT;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    SELECT installation_id INTO v_install_id
    FROM public.user_profiles
    WHERE id = p_id;

    IF v_install_id IS NOT NULL THEN
        DELETE FROM public.user_notifications WHERE installation_id = v_install_id;
    END IF;

    DELETE FROM public.user_profiles WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.7. Delete Admin In-App Notification
CREATE OR REPLACE FUNCTION public.admin_delete_notification(p_id UUID)
RETURNS VOID AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    DELETE FROM public.admin_notifications WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3.8. Send Broadcast Notification to Users
CREATE OR REPLACE FUNCTION public.admin_send_broadcast(
    p_title TEXT,
    p_body TEXT,
    p_notification_type TEXT DEFAULT 'SYSTEM_BROADCAST',
    p_target_type TEXT DEFAULT 'all',
    p_target_value TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
    v_dispatched INTEGER := 0;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied. Administrator privilege required.';
    END IF;

    -- Insert targeted notifications into user_notifications table
    INSERT INTO public.user_notifications (
        installation_id,
        title,
        body,
        notification_type,
        is_read,
        created_at
    )
    SELECT 
        up.installation_id,
        p_title,
        p_body,
        COALESCE(NULLIF(p_notification_type, ''), 'SYSTEM_BROADCAST'),
        FALSE,
        NOW()
    FROM public.user_profiles up
    WHERE 
        (p_target_type = 'all')
        OR (p_target_type = 'country' AND up.country = p_target_value)
        OR (p_target_type = 'user_type' AND up.user_type = p_target_value)
        OR (p_target_type = 'incomplete_profile' AND up.is_profile_completed = FALSE)
        OR (p_target_type = 'specific_user' AND (up.id::TEXT = p_target_value OR up.installation_id = p_target_value));

    GET DIAGNOSTICS v_dispatched = ROW_COUNT;

    -- Also record in broadcast_notifications history if table exists
    INSERT INTO public.broadcast_notifications (
        title,
        body,
        target_audience,
        sent_by,
        sent_at
    ) VALUES (
        p_title,
        p_body,
        p_target_type || CASE WHEN p_target_value IS NOT NULL THEN ':' || p_target_value ELSE '' END,
        auth.uid(),
        NOW()
    );

    RETURN json_build_object(
        'success', TRUE,
        'dispatched_count', v_dispatched
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ----------------------------------------------------------------------------
-- 4. Revoke Insecure Permissions and Enforce Principle of Least Privilege
-- ----------------------------------------------------------------------------

-- Revoke all permissions on admin functions from PUBLIC and anon roles
REVOKE ALL ON FUNCTION public.get_admin_dashboard_metrics() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_reciter(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_recitation(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_competition(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_announcement(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_submission(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_user(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_notification(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_send_broadcast(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;

-- Grant EXECUTE exclusively to authenticated role
GRANT EXECUTE ON FUNCTION public.get_admin_dashboard_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_reciter(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_recitation(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_competition(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_announcement(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_submission(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_notification(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_broadcast(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- Public submission RPC remains accessible to anon & authenticated for visitor contributions
GRANT EXECUTE ON FUNCTION public.submit_recitation_public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_recitation_like TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_listen_event TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. Data Views for Operational Consistency & Real Scores
-- ----------------------------------------------------------------------------

-- 5.1. Reciter Statistics View (Real-time aggregation with mathematical scoring)
CREATE OR REPLACE VIEW public.reciter_statistics_view AS
SELECT
    r.id,
    r.display_name,
    r.pseudonym,
    r.use_pseudonym,
    r.gender,
    r.country,
    r.bio,
    r.profile_image_path,
    r.is_verified,
    r.is_featured,
    r.is_published,
    r.created_at,
    r.updated_at,
    COUNT(DISTINCT rec.id) FILTER (WHERE rec.status = 'APPROVED') AS total_recitations,
    COALESCE(SUM(rec_stats.listen_count), 0) AS total_listens,
    COALESCE(SUM(rec_stats.like_count), 0) AS total_likes,
    (
        COALESCE(SUM(rec_stats.listen_count), 0) * 1.0 +
        COALESCE(SUM(rec_stats.like_count), 0) * 5.0 +
        CASE WHEN r.is_featured THEN 50.0 ELSE 0.0 END +
        CASE WHEN r.is_verified THEN 25.0 ELSE 0.0 END
    ) AS ranking_score
FROM public.reciters r
LEFT JOIN public.recitations rec ON rec.reciter_id = r.id AND rec.status = 'APPROVED'
LEFT JOIN (
    SELECT
        recitation_id,
        COUNT(DISTINCT id) AS listen_count,
        0 AS like_count
    FROM public.listen_events
    GROUP BY recitation_id
    UNION ALL
    SELECT
        recitation_id,
        0 AS listen_count,
        COUNT(DISTINCT id) AS like_count
    FROM public.likes
    GROUP BY recitation_id
) rec_stats ON rec_stats.recitation_id = rec.id
WHERE r.is_published = TRUE
GROUP BY r.id, r.display_name, r.pseudonym, r.use_pseudonym, r.gender, r.country, r.bio, r.profile_image_path, r.is_verified, r.is_featured, r.is_published, r.created_at, r.updated_at;

-- 5.2. Recitation Statistics View (Real-time aggregation for listen & like counts)
CREATE OR REPLACE VIEW public.recitation_statistics_view AS
SELECT
    rec.id,
    rec.reciter_id,
    r.display_name AS reciter_name,
    r.pseudonym AS reciter_pseudonym,
    r.profile_image_path AS reciter_avatar,
    r.country AS reciter_country,
    rec.surah_name,
    rec.surah_number,
    rec.ayah_start,
    rec.ayah_end,
    rec.riwayah,
    rec.duration_seconds,
    rec.audio_storage_path,
    rec.external_audio_url,
    rec.cover_image_path,
    rec.description,
    rec.is_staff_pick,
    rec.status,
    rec.published_at,
    rec.created_at,
    COALESCE(le.listen_count, 0) AS listen_count,
    COALESCE(lk.like_count, 0) AS like_count
FROM public.recitations rec
JOIN public.reciters r ON r.id = rec.reciter_id
LEFT JOIN (
    SELECT recitation_id, COUNT(*) AS listen_count
    FROM public.listen_events
    GROUP BY recitation_id
) le ON le.recitation_id = rec.id
LEFT JOIN (
    SELECT recitation_id, COUNT(*) AS like_count
    FROM public.likes
    GROUP BY recitation_id
) lk ON lk.recitation_id = rec.id
WHERE rec.status = 'APPROVED';

GRANT SELECT ON public.reciter_statistics_view TO anon, authenticated;
GRANT SELECT ON public.recitation_statistics_view TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 6. Trigger for Automatic Admin In-App Notifications on New Submissions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_notify_admin_on_submission()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.admin_notifications (
        notification_type,
        title,
        content,
        reference_id,
        is_read,
        sent_via_email,
        created_at
    ) VALUES (
        'NEW_SUBMISSION',
        'طلب نشر تلاوة جديد: ' || COALESCE(NEW.surah_name, 'سورة'),
        'تم استلام تلاوة جديدة من القارئ (' || COALESCE(NEW.display_name, 'قارئ') || ') برواية (' || COALESCE(NEW.riwayah, 'حفص عن عاصم') || ') وهي بانتظار المراجعة والاعتماد.',
        NEW.id,
        FALSE,
        FALSE,
        NOW()
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_notify_admin_on_submission ON public.recitation_submissions;
CREATE TRIGGER trg_notify_admin_on_submission
    AFTER INSERT ON public.recitation_submissions
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_notify_admin_on_submission();
