-- ══════════════════════════════════════════════════════════
-- NTE Job Tracker — Google Drive Migration
-- Run this once in your Supabase SQL Editor
-- ══════════════════════════════════════════════════════════

-- 1. Add config key for Drive script URL
INSERT INTO config (key, value) VALUES ('GDRIVE_SCRIPT_URL', '')
ON CONFLICT (key) DO NOTHING;

-- 2. RPC to save Google Drive config (admin only)
CREATE OR REPLACE FUNCTION nte_save_gdrive(
  p_token      text,
  p_script_url text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN
    RETURN '{"success":false,"error":"Unauthorized"}'::jsonb;
  END IF;
  INSERT INTO config (key, value) VALUES ('GDRIVE_SCRIPT_URL', p_script_url)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  RETURN '{"success":true}'::jsonb;
END;
$$;
