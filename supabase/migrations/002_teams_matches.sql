-- ============================================================================
-- PorrApp — 002_teams_matches
-- Selecciones + partidos del torneo + log de auditoría de resultados.
-- Los partidos son una FUENTE DE VERDAD GLOBAL: cualquier usuario autenticado
-- puede cargar/editar resultados, y cada cambio queda registrado en
-- match_result_log (quién y cuándo) para mantener la transparencia.
-- ============================================================================


-- ============================================================================
-- Teams (selecciones)
-- ============================================================================

CREATE TABLE IF NOT EXISTS teams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  code TEXT NOT NULL,                       -- ISO-ish, p.ej. ARG, ESP, BRA
  group_letter TEXT,                        -- A..L (null si aún no asignada)
  flag_emoji TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);


-- ============================================================================
-- Matches (partidos)
-- ============================================================================

CREATE TABLE IF NOT EXISTS matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_number INT NOT NULL UNIQUE,         -- 1..104, orden oficial
  stage TEXT NOT NULL CHECK (stage IN ('group','r32','r16','qf','sf','third','final')),
  group_letter TEXT,                        -- solo fase de grupos
  home_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  away_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  home_slot TEXT,                           -- etiqueta cuando el equipo es TBD ("1º Grupo A")
  away_slot TEXT,
  kickoff_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','finished')),
  home_score INT CHECK (home_score >= 0),
  away_score INT CHECK (away_score >= 0),
  result_set_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  result_set_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_matches_kickoff ON matches(kickoff_at);
CREATE INDEX IF NOT EXISTS idx_matches_stage ON matches(stage);


-- ============================================================================
-- Match result log (auditoría)
-- ============================================================================

CREATE TABLE IF NOT EXISTS match_result_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
  set_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  home_score INT,
  away_score INT,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_match_result_log_match ON match_result_log(match_id);


-- ============================================================================
-- Helper: ¿están abiertos los pronósticos de un partido?
-- Cierran 60 minutos antes del kickoff.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_match_locked(p_match_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.matches
    WHERE id = p_match_id
      AND (status = 'finished' OR NOW() >= kickoff_at - INTERVAL '60 minutes')
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================================
-- RLS
-- ============================================================================

ALTER TABLE teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_result_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Teams readable by authenticated" ON teams;
DROP POLICY IF EXISTS "Teams editable by authenticated" ON teams;
DROP POLICY IF EXISTS "Matches readable by authenticated" ON matches;
DROP POLICY IF EXISTS "Matches editable by authenticated" ON matches;
DROP POLICY IF EXISTS "Result log readable by authenticated" ON match_result_log;
DROP POLICY IF EXISTS "Result log insertable by authenticated" ON match_result_log;

-- Lectura abierta a cualquier usuario autenticado.
CREATE POLICY "Teams readable by authenticated"
  ON teams FOR SELECT USING (auth.uid() IS NOT NULL);

-- Cualquier autenticado puede asignar equipos (p.ej. definir cruces de eliminatorias).
CREATE POLICY "Teams editable by authenticated"
  ON teams FOR UPDATE USING (auth.uid() IS NOT NULL);

CREATE POLICY "Matches readable by authenticated"
  ON matches FOR SELECT USING (auth.uid() IS NOT NULL);

-- Cualquier autenticado puede cargar/editar el resultado de un partido.
CREATE POLICY "Matches editable by authenticated"
  ON matches FOR UPDATE USING (auth.uid() IS NOT NULL);

CREATE POLICY "Result log readable by authenticated"
  ON match_result_log FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Result log insertable by authenticated"
  ON match_result_log FOR INSERT WITH CHECK (auth.uid() = set_by);
