-- ══════════════════════════════════════════════════════════
-- NTE Job Tracker — Outsourcing + Rejection Migration
-- Run once in Supabase SQL Editor
-- ══════════════════════════════════════════════════════════

-- 1. Outsource vendors table
CREATE TABLE IF NOT EXISTS outsource_vendors (
  id        SERIAL PRIMARY KEY,
  name      TEXT NOT NULL,
  processes JSONB DEFAULT '[]'::jsonb,
  contact   TEXT DEFAULT '',
  phone     TEXT DEFAULT '',
  active    BOOLEAN DEFAULT TRUE
);

-- 2. Outsource log table
CREATE TABLE IF NOT EXISTS outsource_log (
  id            SERIAL PRIMARY KEY,
  job_id        TEXT NOT NULL,
  stage         TEXT NOT NULL,
  vendor_id     INTEGER NOT NULL,
  vendor_name   TEXT NOT NULL,
  date_sent     TEXT NOT NULL,
  date_received TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Add rejected_qty to jobs
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS rejected_qty INTEGER DEFAULT 0;

-- 4. RLS
ALTER TABLE outsource_vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE outsource_log     ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public_read_outsource_vendors" ON outsource_vendors FOR SELECT TO anon USING (true);
CREATE POLICY "public_read_outsource_log"     ON outsource_log     FOR SELECT TO anon USING (true);
CREATE POLICY "no_write_ov" ON outsource_vendors FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_ov" ON outsource_vendors FOR UPDATE TO anon USING (false);
CREATE POLICY "no_write_ol" ON outsource_log FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_ol" ON outsource_log FOR UPDATE TO anon USING (false);

-- 5. Save outsource vendor
CREATE OR REPLACE FUNCTION nte_save_outsource_vendor(p_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text; v_id integer;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  v_id := NULLIF(p_data->>'id','')::integer;
  IF v_id IS NOT NULL THEN
    UPDATE outsource_vendors SET
      name      = TRIM(p_data->>'name'),
      processes = COALESCE((p_data->>'processes')::jsonb,'[]'::jsonb),
      contact   = COALESCE(p_data->>'contact',''),
      phone     = COALESCE(p_data->>'phone',''),
      active    = COALESCE((p_data->>'active')::boolean,true)
    WHERE id = v_id;
    RETURN '{"success":true,"action":"updated"}'::jsonb;
  ELSE
    INSERT INTO outsource_vendors (name,processes,contact,phone)
    VALUES (TRIM(p_data->>'name'),COALESCE((p_data->>'processes')::jsonb,'[]'::jsonb),COALESCE(p_data->>'contact',''),COALESCE(p_data->>'phone',''));
    RETURN '{"success":true,"action":"created"}'::jsonb;
  END IF;
END;
$$;

-- 6. Delete outsource vendor (hard delete — safe since log stores vendor_name text)
CREATE OR REPLACE FUNCTION nte_delete_outsource_vendor(p_token text, p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  DELETE FROM outsource_vendors WHERE id = p_id;
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- 7. Send stage to outsourcing
CREATE OR REPLACE FUNCTION nte_send_outsource(
  p_token       text,
  p_job_id      text,
  p_stage       text,
  p_vendor_id   integer,
  p_vendor_name text,
  p_date_sent   text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_stages jsonb;
  v_found  boolean;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  SELECT stages_json INTO v_stages FROM jobs WHERE job_id = p_job_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Job not found"}'::jsonb; END IF;
  SELECT bool_or((elem->>'stage')=p_stage) INTO v_found
  FROM jsonb_array_elements(COALESCE(v_stages,'[]'::jsonb)) elem;
  IF v_found THEN
    v_stages := (SELECT jsonb_agg(
      CASE WHEN (elem->>'stage')=p_stage
      THEN elem || jsonb_build_object('outsourced',true,'vendor_id',p_vendor_id,'vendor_name',p_vendor_name,'date_sent',p_date_sent)
      ELSE elem END) FROM jsonb_array_elements(v_stages) elem);
  ELSE
    v_stages := COALESCE(v_stages,'[]'::jsonb) || jsonb_build_array(
      jsonb_build_object('stage',p_stage,'planned',true,'done',false,'outsourced',true,
        'vendor_id',p_vendor_id,'vendor_name',p_vendor_name,'date_sent',p_date_sent,'date',null));
  END IF;
  UPDATE jobs SET stages_json=v_stages,updated_at=NOW() WHERE job_id=p_job_id;
  INSERT INTO outsource_log(job_id,stage,vendor_id,vendor_name,date_sent)
  VALUES(p_job_id,p_stage,p_vendor_id,p_vendor_name,p_date_sent);
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- 8. Receive back from outsourcing
CREATE OR REPLACE FUNCTION nte_receive_outsource(
  p_token         text,
  p_log_id        integer,
  p_date_received text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_job_id text;
  v_stage  text;
  v_stages jsonb;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  SELECT job_id,stage INTO v_job_id,v_stage FROM outsource_log WHERE id=p_log_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Log not found"}'::jsonb; END IF;
  UPDATE outsource_log SET date_received=p_date_received WHERE id=p_log_id;
  SELECT stages_json INTO v_stages FROM jobs WHERE job_id=v_job_id;
  v_stages := (SELECT jsonb_agg(
    CASE WHEN (elem->>'stage')=v_stage
    THEN elem || jsonb_build_object('done',true,'date',p_date_received,'date_received',p_date_received)
    ELSE elem END) FROM jsonb_array_elements(COALESCE(v_stages,'[]'::jsonb)) elem);
  UPDATE jobs SET stages_json=v_stages,updated_at=NOW() WHERE job_id=v_job_id;
  RETURN json_build_object('success',true,'job_id',v_job_id,'stage',v_stage);
END;
$$;

-- 9. Reject job (replace)
CREATE OR REPLACE FUNCTION nte_reject_job(p_token text, p_job_id text, p_qty integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token,'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE jobs SET rejected_qty=p_qty,updated_at=NOW() WHERE job_id=p_job_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Job not found"}'::jsonb; END IF;
  RETURN '{"success":true}'::jsonb;
END;
$$;
