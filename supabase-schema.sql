-- ============================================================
-- NTE JOB TRACKER — Supabase Schema  v1
-- New Tech Engineers, Pune
-- ============================================================
-- HOW TO SET UP (one-time, ~5 minutes):
--
--  1. Go to https://supabase.com and create a free project
--  2. In your project → SQL Editor → paste this entire file → Run
--  3. Go to Project Settings → API and copy:
--       • Project URL  → paste as SUPABASE_URL  in index.html
--       • anon public key → paste as SUPABASE_ANON_KEY in index.html
--  4. Open index.html in a browser (or deploy to Netlify / Vercel)
--
-- Default login credentials (change passwords in the credentials table):
--   Admin:      NTE@2026
--   Supervisor: floor@123
--   Customer:   view@123
-- ============================================================

-- ── Extensions ───────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Sequence for job IDs ──────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS job_number_seq START 1000;

-- ── Tables ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS jobs (
  job_id        TEXT PRIMARY KEY,
  sr_no         INTEGER,
  company       TEXT,
  job_type      TEXT DEFAULT 'LABOUR',
  po_no         TEXT,
  po_date       TEXT,
  job_card_no   TEXT,
  drg_no        TEXT,
  description   TEXT,
  quantity      TEXT,
  received_date TEXT,
  dod           TEXT,
  supervisor    TEXT,
  priority      TEXT DEFAULT 'NORMAL',
  status        TEXT DEFAULT 'RECEIVED',
  current_stage TEXT,
  stages_json   JSONB DEFAULT '[]'::jsonb,
  challan_no    TEXT,
  challan_date  TEXT,
  bill_no       TEXT,
  bill_date     TEXT,
  notes         TEXT,
  drawing_url   TEXT,
  drawing_name  TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS companies (
  id      SERIAL PRIMARY KEY,
  name    TEXT UNIQUE NOT NULL,
  contact TEXT DEFAULT '',
  phone   TEXT DEFAULT '',
  email   TEXT DEFAULT '',
  address TEXT DEFAULT '',
  active  BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS supervisors (
  id     SERIAL PRIMARY KEY,
  name   TEXT NOT NULL,
  role   TEXT DEFAULT '',
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS processes (
  id           SERIAL PRIMARY KEY,
  code         TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL,
  sort_order   INTEGER DEFAULT 99,
  active       BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS config (
  key   TEXT PRIMARY KEY,
  value TEXT DEFAULT ''
);

-- Auth: role-based shared passwords (bcrypt-hashed)
CREATE TABLE IF NOT EXISTS credentials (
  role          TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL,
  display_name  TEXT
);

-- Sessions: 8-hour expiry tokens
CREATE TABLE IF NOT EXISTS sessions (
  token      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role       TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '8 hours'
);

-- ── Row Level Security ────────────────────────────────────

ALTER TABLE jobs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies   ENABLE ROW LEVEL SECURITY;
ALTER TABLE supervisors ENABLE ROW LEVEL SECURITY;
ALTER TABLE processes   ENABLE ROW LEVEL SECURITY;
ALTER TABLE config      ENABLE ROW LEVEL SECURITY;
ALTER TABLE credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;

-- Public reads (anon key can SELECT)
CREATE POLICY "public_read_jobs"        ON jobs        FOR SELECT TO anon USING (true);
CREATE POLICY "public_read_companies"   ON companies   FOR SELECT TO anon USING (true);
CREATE POLICY "public_read_supervisors" ON supervisors FOR SELECT TO anon USING (true);
CREATE POLICY "public_read_processes"   ON processes   FOR SELECT TO anon USING (true);
CREATE POLICY "public_read_config"      ON config      FOR SELECT TO anon USING (true);
-- credentials and sessions: no direct access — only via SECURITY DEFINER functions

-- Block direct writes from anon (all writes go through secure RPC functions)
CREATE POLICY "no_write_jobs"        ON jobs        FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_jobs"       ON jobs        FOR UPDATE TO anon USING (false);
CREATE POLICY "no_delete_jobs"       ON jobs        FOR DELETE TO anon USING (false);
CREATE POLICY "no_write_companies"   ON companies   FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_companies"  ON companies   FOR UPDATE TO anon USING (false);
CREATE POLICY "no_write_supervisors" ON supervisors FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_supervisors"ON supervisors FOR UPDATE TO anon USING (false);
CREATE POLICY "no_write_processes"   ON processes   FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_processes"  ON processes   FOR UPDATE TO anon USING (false);
CREATE POLICY "no_write_config"      ON config      FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "no_update_config"     ON config      FOR UPDATE TO anon USING (false);

-- ── Helper: verify session token ─────────────────────────
-- Returns the role if valid, NULL if invalid/expired
-- p_need: 'write' = admin or supervisor, 'admin' = admin only, 'any' = any role

CREATE OR REPLACE FUNCTION check_session(p_token text, p_need text DEFAULT 'write')
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  DELETE FROM sessions WHERE expires_at < NOW();
  BEGIN
    SELECT role INTO v_role FROM sessions
    WHERE token = p_token::uuid AND expires_at > NOW();
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END;
  IF v_role IS NULL THEN RETURN NULL; END IF;
  IF p_need = 'write'  AND v_role = 'customer' THEN RETURN NULL; END IF;
  IF p_need = 'admin'  AND v_role != 'admin'   THEN RETURN NULL; END IF;
  RETURN v_role;
END;
$$;

-- ── Login ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_login(p_role text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash text;
  v_token uuid;
BEGIN
  SELECT password_hash INTO v_hash FROM credentials WHERE role = p_role;
  IF v_hash IS NULL OR crypt(p_password, v_hash) != v_hash THEN
    RETURN '{"success":false,"error":"Invalid credentials"}'::jsonb;
  END IF;
  INSERT INTO sessions (role) VALUES (p_role) RETURNING token INTO v_token;
  RETURN json_build_object('success', true, 'role', p_role, 'token', v_token::text)::jsonb;
END;
$$;

-- ── Save / Update Job ─────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_save_job(p_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_job_id text;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;

  v_job_id := NULLIF(p_data->>'JOB_ID', '');

  IF v_job_id IS NOT NULL THEN
    UPDATE jobs SET
      company       = CASE WHEN p_data ? 'COMPANY'       THEN COALESCE(NULLIF(p_data->>'COMPANY',''),       company)       ELSE company       END,
      job_type      = CASE WHEN p_data ? 'JOB_TYPE'      THEN COALESCE(NULLIF(p_data->>'JOB_TYPE',''),      job_type)      ELSE job_type      END,
      po_no         = CASE WHEN p_data ? 'PO_NO'         THEN p_data->>'PO_NO'                                             ELSE po_no         END,
      po_date       = CASE WHEN p_data ? 'PO_DATE'       THEN NULLIF(p_data->>'PO_DATE','')                               ELSE po_date       END,
      job_card_no   = CASE WHEN p_data ? 'JOB_CARD_NO'   THEN p_data->>'JOB_CARD_NO'                                      ELSE job_card_no   END,
      drg_no        = CASE WHEN p_data ? 'DRG_NO'        THEN p_data->>'DRG_NO'                                           ELSE drg_no        END,
      description   = CASE WHEN p_data ? 'DESCRIPTION'   THEN COALESCE(NULLIF(p_data->>'DESCRIPTION',''),   description)   ELSE description   END,
      quantity      = CASE WHEN p_data ? 'QUANTITY'       THEN p_data->>'QUANTITY'                                         ELSE quantity      END,
      received_date = CASE WHEN p_data ? 'RECEIVED_DATE'  THEN NULLIF(p_data->>'RECEIVED_DATE','')                        ELSE received_date END,
      dod           = CASE WHEN p_data ? 'DOD'            THEN NULLIF(p_data->>'DOD','')                                  ELSE dod           END,
      supervisor    = CASE WHEN p_data ? 'SUPERVISOR'     THEN p_data->>'SUPERVISOR'                                       ELSE supervisor    END,
      priority      = CASE WHEN p_data ? 'PRIORITY'       THEN COALESCE(NULLIF(p_data->>'PRIORITY',''),     priority)      ELSE priority      END,
      status        = CASE WHEN p_data ? 'STATUS'         THEN COALESCE(NULLIF(p_data->>'STATUS',''),       status)        ELSE status        END,
      current_stage = CASE WHEN p_data ? 'CURRENT_STAGE'  THEN p_data->>'CURRENT_STAGE'                                   ELSE current_stage END,
      stages_json   = CASE WHEN p_data ? 'STAGES_JSON'    THEN (p_data->>'STAGES_JSON')::jsonb                            ELSE stages_json   END,
      challan_no    = CASE WHEN p_data ? 'CHALLAN_NO'     THEN p_data->>'CHALLAN_NO'                                      ELSE challan_no    END,
      challan_date  = CASE WHEN p_data ? 'CHALLAN_DATE'   THEN NULLIF(p_data->>'CHALLAN_DATE','')                         ELSE challan_date  END,
      bill_no       = CASE WHEN p_data ? 'BILL_NO'        THEN p_data->>'BILL_NO'                                         ELSE bill_no       END,
      bill_date     = CASE WHEN p_data ? 'BILL_DATE'      THEN NULLIF(p_data->>'BILL_DATE','')                            ELSE bill_date     END,
      notes         = CASE WHEN p_data ? 'NOTES'          THEN p_data->>'NOTES'                                           ELSE notes         END,
      updated_at    = NOW()
    WHERE job_id = v_job_id;
    IF NOT FOUND THEN RETURN '{"success":false,"error":"Job not found"}'::jsonb; END IF;
    RETURN json_build_object('success', true, 'job_id', v_job_id, 'action', 'updated');
  ELSE
    v_job_id := 'NTE-' || TO_CHAR(NOW(), 'YY') || '-' || LPAD(nextval('job_number_seq')::text, 5, '0');
    INSERT INTO jobs (
      job_id, company, job_type, po_no, po_date, job_card_no, drg_no,
      description, quantity, received_date, dod, supervisor, priority, status,
      current_stage, stages_json, challan_no, challan_date, bill_no, bill_date, notes
    ) VALUES (
      v_job_id,
      p_data->>'COMPANY',
      COALESCE(NULLIF(p_data->>'JOB_TYPE',''), 'LABOUR'),
      p_data->>'PO_NO', NULLIF(p_data->>'PO_DATE',''),
      p_data->>'JOB_CARD_NO', p_data->>'DRG_NO',
      p_data->>'DESCRIPTION', p_data->>'QUANTITY',
      NULLIF(p_data->>'RECEIVED_DATE',''), NULLIF(p_data->>'DOD',''),
      p_data->>'SUPERVISOR',
      COALESCE(NULLIF(p_data->>'PRIORITY',''), 'NORMAL'),
      COALESCE(NULLIF(p_data->>'STATUS',''), 'RECEIVED'),
      NULLIF(p_data->>'CURRENT_STAGE',''),
      COALESCE(NULLIF(p_data->>'STAGES_JSON','')::jsonb, '[]'::jsonb),
      p_data->>'CHALLAN_NO', NULLIF(p_data->>'CHALLAN_DATE',''),
      p_data->>'BILL_NO', NULLIF(p_data->>'BILL_DATE',''),
      p_data->>'NOTES'
    );
    RETURN json_build_object('success', true, 'job_id', v_job_id, 'action', 'created');
  END IF;
END;
$$;

-- ── Delete Job ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_delete_job(p_token text, p_job_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  DELETE FROM jobs WHERE job_id = p_job_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Not found"}'::jsonb; END IF;
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Update Job Stage ──────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_update_stage(
  p_token        text,
  p_job_id       text,
  p_stage        text,
  p_auto_progress boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role       text;
  v_job        jobs%ROWTYPE;
  v_stages     jsonb;
  v_found      boolean;
  v_date       text;
  v_new_status text;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;

  SELECT * INTO v_job FROM jobs WHERE job_id = p_job_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Job not found"}'::jsonb; END IF;

  v_stages     := COALESCE(v_job.stages_json, '[]'::jsonb);
  v_date       := TO_CHAR(NOW(), 'DD.MM.YY');
  v_new_status := v_job.status;

  IF p_auto_progress AND v_job.status = 'RECEIVED' THEN
    v_new_status := 'IN PROGRESS';
  END IF;

  SELECT
    jsonb_agg(
      CASE WHEN (elem->>'stage') = p_stage
      THEN jsonb_set(jsonb_set(elem, '{done}', 'true'::jsonb), '{date}', to_jsonb(v_date))
      ELSE elem END
    ),
    bool_or((elem->>'stage') = p_stage)
  INTO v_stages, v_found
  FROM jsonb_array_elements(v_stages) elem;

  IF NOT v_found OR v_found IS NULL THEN
    v_stages := COALESCE(v_stages, '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('stage', p_stage, 'planned', true, 'done', true, 'date', v_date));
  END IF;

  UPDATE jobs SET
    current_stage = p_stage,
    status        = v_new_status,
    stages_json   = v_stages,
    updated_at    = NOW()
  WHERE job_id = p_job_id;

  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Quick Status Update ───────────────────────────────────

CREATE OR REPLACE FUNCTION nte_quick_status(
  p_token        text,
  p_job_id       text,
  p_status       text,
  p_challan_no   text DEFAULT NULL,
  p_challan_date text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE jobs SET
    status       = p_status,
    challan_no   = COALESCE(p_challan_no,   challan_no),
    challan_date = COALESCE(p_challan_date, challan_date),
    updated_at   = NOW()
  WHERE job_id = p_job_id;
  IF NOT FOUND THEN RETURN '{"success":false,"error":"Job not found"}'::jsonb; END IF;
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Update Drawing URL ────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_update_drawing(
  p_token  text,
  p_job_id text,
  p_url    text,
  p_name   text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'write');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE jobs SET drawing_url = p_url, drawing_name = p_name, updated_at = NOW()
  WHERE job_id = p_job_id;
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Save Company ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_save_company(p_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_lookup text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;

  v_lookup := COALESCE(NULLIF(p_data->>'originalName', ''), p_data->>'name');

  IF EXISTS (SELECT 1 FROM companies WHERE LOWER(name) = LOWER(v_lookup)) THEN
    UPDATE companies SET
      name    = TRIM(p_data->>'name'),
      contact = COALESCE(p_data->>'contact', ''),
      phone   = COALESCE(p_data->>'phone',   ''),
      email   = COALESCE(p_data->>'email',   ''),
      address = COALESCE(p_data->>'address', ''),
      active  = COALESCE((p_data->>'active')::boolean, true)
    WHERE LOWER(name) = LOWER(v_lookup);
    RETURN '{"success":true,"action":"updated"}'::jsonb;
  ELSE
    INSERT INTO companies (name, contact, phone, email, address, active)
    VALUES (
      TRIM(p_data->>'name'),
      COALESCE(p_data->>'contact', ''), COALESCE(p_data->>'phone',   ''),
      COALESCE(p_data->>'email',   ''), COALESCE(p_data->>'address', ''),
      COALESCE((p_data->>'active')::boolean, true)
    );
    RETURN '{"success":true,"action":"created"}'::jsonb;
  END IF;
END;
$$;

-- ── Toggle Company Active ─────────────────────────────────

CREATE OR REPLACE FUNCTION nte_toggle_company(p_token text, p_name text, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE companies SET active = p_active WHERE LOWER(name) = LOWER(p_name);
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Save Process ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_save_process(p_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_lookup text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;

  v_lookup := COALESCE(NULLIF(p_data->>'originalCode', ''), p_data->>'code');

  IF EXISTS (SELECT 1 FROM processes WHERE UPPER(code) = UPPER(v_lookup)) THEN
    UPDATE processes SET
      code         = UPPER(TRIM(p_data->>'code')),
      display_name = COALESCE(NULLIF(TRIM(p_data->>'name'), ''), display_name),
      sort_order   = COALESCE(NULLIF(p_data->>'order', '')::int, sort_order),
      active       = COALESCE((p_data->>'active')::boolean, active)
    WHERE UPPER(code) = UPPER(v_lookup);
    RETURN '{"success":true,"action":"updated"}'::jsonb;
  ELSE
    INSERT INTO processes (code, display_name, sort_order, active)
    VALUES (
      UPPER(TRIM(p_data->>'code')),
      TRIM(p_data->>'name'),
      COALESCE(NULLIF(p_data->>'order', '')::int, 99),
      COALESCE((p_data->>'active')::boolean, true)
    );
    RETURN '{"success":true,"action":"created"}'::jsonb;
  END IF;
END;
$$;

-- ── Deactivate Process ────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_delete_process(p_token text, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE processes SET active = false WHERE UPPER(code) = UPPER(p_code);
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Save Supervisor ───────────────────────────────────────

CREATE OR REPLACE FUNCTION nte_save_supervisor(p_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role   text;
  v_lookup text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;

  v_lookup := COALESCE(NULLIF(p_data->>'originalName', ''), p_data->>'name');

  IF EXISTS (SELECT 1 FROM supervisors WHERE LOWER(name) = LOWER(v_lookup)) THEN
    UPDATE supervisors SET
      name   = TRIM(p_data->>'name'),
      role   = COALESCE(p_data->>'role', ''),
      active = COALESCE((p_data->>'active')::boolean, true)
    WHERE LOWER(name) = LOWER(v_lookup);
    RETURN '{"success":true,"action":"updated"}'::jsonb;
  ELSE
    INSERT INTO supervisors (name, role, active)
    VALUES (
      TRIM(p_data->>'name'),
      COALESCE(p_data->>'role', ''),
      COALESCE((p_data->>'active')::boolean, true)
    );
    RETURN '{"success":true,"action":"created"}'::jsonb;
  END IF;
END;
$$;

-- ── Deactivate Supervisor ─────────────────────────────────

CREATE OR REPLACE FUNCTION nte_delete_supervisor(p_token text, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  UPDATE supervisors SET active = false WHERE LOWER(name) = LOWER(p_name);
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Save Cloudinary Config ────────────────────────────────

CREATE OR REPLACE FUNCTION nte_save_cloudinary(
  p_token         text,
  p_cloud_name    text,
  p_upload_preset text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_role text;
BEGIN
  v_role := check_session(p_token, 'admin');
  IF v_role IS NULL THEN RETURN '{"success":false,"error":"Unauthorized"}'::jsonb; END IF;
  INSERT INTO config (key, value) VALUES ('CLOUDINARY_CLOUD_NAME',    p_cloud_name)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  INSERT INTO config (key, value) VALUES ('CLOUDINARY_UPLOAD_PRESET', p_upload_preset)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  RETURN '{"success":true}'::jsonb;
END;
$$;

-- ── Seed Data ─────────────────────────────────────────────

-- Credentials (bcrypt-hashed passwords)
INSERT INTO credentials (role, password_hash, display_name) VALUES
  ('admin',      crypt('NTE@2026',   gen_salt('bf')), 'Admin / Office Staff'),
  ('supervisor', crypt('floor@123',  gen_salt('bf')), 'Shop Floor Supervisor'),
  ('customer',   crypt('view@123',   gen_salt('bf')), 'Customer (View Only)')
ON CONFLICT (role) DO NOTHING;

-- Default companies
INSERT INTO companies (name) VALUES
  ('ARTECH WELDERS'), ('MAFLOW'), ('KAESER COMPRESSORS'), ('ATS'), ('SPARKONIX'),
  ('ENORISE'), ('ELECTRIPNUMATICS'), ('MINDARIKA-TAMILNADU'), ('MEGACON LOGISTICS'),
  ('AMPHENOL-CASTING'), ('AMPHENOL'), ('MINDARIKA-CHAKAN'), ('MINDARIKA-HARYANA'),
  ('MINDARIKA-GUJARAT'), ('MAXIS'), ('HITACHI ASTMO'), ('TERMINAL TECHNOLOGIES'),
  ('SPOOL'), ('RADIANCE')
ON CONFLICT (name) DO NOTHING;

-- Default processes
INSERT INTO processes (code, display_name, sort_order) VALUES
  ('T',       'Turning',              1),
  ('MTR',     'Milling / Raw',        2),
  ('MILLING', 'Milling',              3),
  ('VMC',     'VMC',                  4),
  ('HT',      'Heat Treatment',       5),
  ('CG',      'Cylindrical Grinding', 6),
  ('SG',      'Surface Grinding',     7),
  ('W/E',     'Wire EDM',             8),
  ('W/C',     'Wire Cut',             9),
  ('P/G',     'Pin Grinding',         10),
  ('M/O',     'Manual Operation',     11),
  ('RA',      'Raw',                  12),
  ('S/F',     'Surface Finish',       13),
  ('TIPPING', 'Tipping',              14),
  ('DRO',     'DRO',                  15),
  ('WELDING', 'Welding',              16),
  ('IGS',     'IGS',                  17),
  ('AASTHA',  'Aastha',               18)
ON CONFLICT (code) DO NOTHING;

-- Default supervisors
INSERT INTO supervisors (name) VALUES
  ('Vikas'), ('Vijay'), ('Sanjay'), ('Avdesh'),
  ('Chakraji'), ('Sonu'), ('Shivansh'), ('Ashish')
ON CONFLICT DO NOTHING;

-- Config defaults
INSERT INTO config (key, value) VALUES
  ('CLOUDINARY_CLOUD_NAME',    ''),
  ('CLOUDINARY_UPLOAD_PRESET', '')
ON CONFLICT (key) DO NOTHING;
