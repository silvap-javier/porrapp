-- ============================================================================
-- PorrApp — schema completo (001→006 combinadas). Pegar en el SQL Editor de
-- Supabase y ejecutar (Run). Idempotente: se puede re-ejecutar sin romper.
-- ============================================================================


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  001_profiles.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 001_profiles
-- Perfiles sincronizados desde auth.users + trigger base.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ============================================================================
-- Profiles
-- ============================================================================

CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  name TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Crea el perfil automáticamente al insertar un auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', '')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;

-- Perfiles legibles por todos (solo nombre/avatar) para mostrar rankings.
CREATE POLICY "Profiles are viewable by everyone"
  ON profiles FOR SELECT USING (true);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id);

CREATE INDEX IF NOT EXISTS idx_profiles_email ON profiles(email);


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  002_teams_matches.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

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


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  003_leagues.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 003_leagues
-- Ligas privadas entre amigos + miembros. Helpers SECURITY DEFINER para
-- evitar recursión en RLS (mismo patrón que FinanzApp).
-- ============================================================================


-- ============================================================================
-- Tablas (se crean ANTES que las funciones: los cuerpos SQL validan las
-- referencias a tablas al crearse, así que la tabla debe existir primero).
-- ============================================================================

CREATE TABLE IF NOT EXISTS leagues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  owner_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  join_code TEXT NOT NULL UNIQUE,
  scoring JSONB NOT NULL DEFAULT '{"exact": 3, "result": 1}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE TABLE IF NOT EXISTS league_members (
  league_id UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  joined_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  PRIMARY KEY (league_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_league_members_user ON league_members(user_id);
CREATE INDEX IF NOT EXISTS idx_league_members_league ON league_members(league_id);

ALTER TABLE leagues ENABLE ROW LEVEL SECURITY;
ALTER TABLE league_members ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- Helpers de membresía (SECURITY DEFINER para evitar recursión en RLS)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_league_member(p_league_id UUID, p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.league_members
    WHERE league_id = p_league_id AND user_id = p_user_id
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_league_owner(p_league_id UUID, p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.league_members
    WHERE league_id = p_league_id AND user_id = p_user_id AND role = 'owner'
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Resuelve una liga a partir de su código de invitación (bypassa RLS para que
-- un no-miembro pueda unirse conociendo el código).
CREATE OR REPLACE FUNCTION public.league_id_by_code(p_code TEXT)
RETURNS UUID AS $$
  SELECT id FROM public.leagues WHERE join_code = upper(trim(p_code));
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================================
-- Políticas: leagues
-- ============================================================================

DROP POLICY IF EXISTS "Leagues visible to members" ON leagues;
DROP POLICY IF EXISTS "Authenticated users can create leagues" ON leagues;
DROP POLICY IF EXISTS "League owners can update leagues" ON leagues;
DROP POLICY IF EXISTS "League owners can delete leagues" ON leagues;

CREATE POLICY "Leagues visible to members"
  ON leagues FOR SELECT
  USING (public.is_league_member(id, auth.uid()) OR auth.uid() = owner_id);

CREATE POLICY "Authenticated users can create leagues"
  ON leagues FOR INSERT
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "League owners can update leagues"
  ON leagues FOR UPDATE
  USING (public.is_league_owner(id, auth.uid()));

CREATE POLICY "League owners can delete leagues"
  ON leagues FOR DELETE
  USING (public.is_league_owner(id, auth.uid()));


-- ============================================================================
-- Políticas: league_members
-- ============================================================================

DROP POLICY IF EXISTS "Members visible to league members" ON league_members;
DROP POLICY IF EXISTS "Members can be added" ON league_members;
DROP POLICY IF EXISTS "Owners or self can remove members" ON league_members;

CREATE POLICY "Members visible to league members"
  ON league_members FOR SELECT
  USING (public.is_league_member(league_id, auth.uid()));

CREATE POLICY "Members can be added"
  ON league_members FOR INSERT
  WITH CHECK (
    -- Owner se añade a sí mismo al crear la liga
    (auth.uid() = user_id AND role = 'owner')
    OR
    -- Un usuario se une a sí mismo como member (vía código de invitación)
    (auth.uid() = user_id AND role = 'member')
    OR
    -- El owner añade a otros
    public.is_league_owner(league_id, auth.uid())
  );

CREATE POLICY "Owners or self can remove members"
  ON league_members FOR DELETE
  USING (
    public.is_league_owner(league_id, auth.uid())
    OR auth.uid() = user_id
  );


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  004_predictions.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 004_predictions
-- Pronósticos por partido + macro picks de torneo + resultado del torneo.
-- Los pronósticos son GLOBALES por usuario: se hacen una vez y valen en todas
-- las ligas en las que participa.
-- ============================================================================


-- ============================================================================
-- Helper: ¿ya empezó el torneo? (primer partido con kickoff pasado)
-- Bloquea los macro picks una vez arranca el Mundial.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.tournament_started()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.matches WHERE NOW() >= kickoff_at
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================================
-- Pronósticos de partido
-- ============================================================================

CREATE TABLE IF NOT EXISTS match_predictions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
  home_score INT NOT NULL CHECK (home_score >= 0),
  away_score INT NOT NULL CHECK (away_score >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  UNIQUE (user_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_match_predictions_user ON match_predictions(user_id);
CREATE INDEX IF NOT EXISTS idx_match_predictions_match ON match_predictions(match_id);


-- ============================================================================
-- Macro picks (campeón, subcampeón, goleador)
-- ============================================================================

CREATE TABLE IF NOT EXISTS macro_predictions (
  user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  champion_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  runnerup_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  top_scorer TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);


-- ============================================================================
-- Resultado real del torneo (fila única, la edita el panel de resultados)
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_outcome (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  champion_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  runnerup_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  top_scorer TEXT,
  set_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

INSERT INTO tournament_outcome (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- RLS
-- ============================================================================

ALTER TABLE match_predictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE macro_predictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournament_outcome ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own predictions or locked matches readable" ON match_predictions;
DROP POLICY IF EXISTS "Insert own predictions" ON match_predictions;
DROP POLICY IF EXISTS "Update own predictions" ON match_predictions;
DROP POLICY IF EXISTS "Delete own predictions" ON match_predictions;

-- Cada quien ve los suyos; los de otros sólo cuando el partido ya está
-- bloqueado (cerrado el plazo) — así nadie copia pronósticos antes de tiempo.
CREATE POLICY "Own predictions or locked matches readable"
  ON match_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.is_match_locked(match_id));

CREATE POLICY "Insert own predictions"
  ON match_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own predictions"
  ON match_predictions FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Delete own predictions"
  ON match_predictions FOR DELETE
  USING (auth.uid() = user_id);


DROP POLICY IF EXISTS "Own macro or after start readable" ON macro_predictions;
DROP POLICY IF EXISTS "Upsert own macro" ON macro_predictions;
DROP POLICY IF EXISTS "Update own macro" ON macro_predictions;

CREATE POLICY "Own macro or after start readable"
  ON macro_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.tournament_started());

CREATE POLICY "Upsert own macro"
  ON macro_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own macro"
  ON macro_predictions FOR UPDATE
  USING (auth.uid() = user_id);


DROP POLICY IF EXISTS "Outcome readable by authenticated" ON tournament_outcome;
DROP POLICY IF EXISTS "Outcome editable by authenticated" ON tournament_outcome;

CREATE POLICY "Outcome readable by authenticated"
  ON tournament_outcome FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Outcome editable by authenticated"
  ON tournament_outcome FOR UPDATE USING (auth.uid() IS NOT NULL);


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  005_scoring.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 005_scoring
-- Reglas de puntuación + funciones de ranking.
--   · Marcador exacto = 3 pts (bonus) + 1 pt (resultado) = 4
--   · Solo resultado correcto (1X2) = 1 pt
--   · Macro picks: campeón = 10, subcampeón = 5, goleador = 5
-- El ranking se calcula con funciones SECURITY DEFINER para poder sumar los
-- puntos de TODOS los miembros de la liga (los pronósticos ajenos no son
-- legibles por RLS hasta que el partido se bloquea, pero el ranking sí).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.score_match(
  ph INT, pa INT, ah INT, aa INT,
  exact_pts INT DEFAULT 3, result_pts INT DEFAULT 1
)
RETURNS INT AS $$
  SELECT CASE
    WHEN ph IS NULL OR pa IS NULL OR ah IS NULL OR aa IS NULL THEN 0
    WHEN ph = ah AND pa = aa THEN exact_pts + result_pts
    WHEN sign(ph - pa) = sign(ah - aa) THEN result_pts
    ELSE 0
  END;
$$ LANGUAGE sql IMMUTABLE;


-- Puntos de macro picks de un usuario contra el resultado real del torneo.
CREATE OR REPLACE FUNCTION public.macro_points(p_user_id UUID)
RETURNS INT AS $$
  SELECT COALESCE((
    SELECT
      (CASE WHEN mp.champion_team_id IS NOT NULL
             AND mp.champion_team_id = o.champion_team_id THEN 10 ELSE 0 END)
    + (CASE WHEN mp.runnerup_team_id IS NOT NULL
             AND mp.runnerup_team_id = o.runnerup_team_id THEN 5 ELSE 0 END)
    + (CASE WHEN mp.top_scorer IS NOT NULL AND o.top_scorer IS NOT NULL
             AND lower(trim(mp.top_scorer)) = lower(trim(o.top_scorer)) THEN 5 ELSE 0 END)
    FROM public.macro_predictions mp
    CROSS JOIN public.tournament_outcome o
    WHERE mp.user_id = p_user_id AND o.id = 1
  ), 0);
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- Desglose de puntos de partidos de un usuario.
CREATE OR REPLACE FUNCTION public.match_points(p_user_id UUID)
RETURNS TABLE (total INT, exact_count INT, result_count INT, predicted_count INT) AS $$
  SELECT
    COALESCE(SUM(public.score_match(mp.home_score, mp.away_score, m.home_score, m.away_score)), 0)::INT,
    COALESCE(SUM(CASE WHEN m.home_score = mp.home_score AND m.away_score = mp.away_score THEN 1 ELSE 0 END), 0)::INT,
    COALESCE(SUM(CASE WHEN m.home_score <> mp.home_score OR m.away_score <> mp.away_score
                       THEN (CASE WHEN sign(mp.home_score - mp.away_score) = sign(m.home_score - m.away_score) THEN 1 ELSE 0 END)
                       ELSE 0 END), 0)::INT,
    COUNT(*)::INT
  FROM public.match_predictions mp
  JOIN public.matches m ON m.id = mp.match_id
  WHERE mp.user_id = p_user_id AND m.status = 'finished';
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- Ranking de una liga. Solo accesible para miembros de la liga.
CREATE OR REPLACE FUNCTION public.league_leaderboard(p_league_id UUID)
RETURNS TABLE (
  user_id UUID,
  name TEXT,
  email TEXT,
  total_points INT,
  match_points INT,
  macro_points INT,
  exact_count INT,
  result_count INT,
  predicted_count INT
) AS $$
  SELECT
    p.id,
    p.name,
    p.email,
    (mp.total + public.macro_points(p.id))::INT AS total_points,
    mp.total AS match_points,
    public.macro_points(p.id) AS macro_points,
    mp.exact_count,
    mp.result_count,
    mp.predicted_count
  FROM public.league_members lm
  JOIN public.profiles p ON p.id = lm.user_id
  CROSS JOIN LATERAL public.match_points(p.id) mp
  WHERE lm.league_id = p_league_id
    AND public.is_league_member(p_league_id, auth.uid())
  ORDER BY total_points DESC, mp.exact_count DESC, p.name ASC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  006_seed_worldcup2026.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 006_seed_worldcup2026
-- Carga inicial del Mundial 2026: 48 selecciones en 12 grupos (A–L), 72
-- partidos de fase de grupos (round-robin) y 32 de eliminatorias.
--
-- ⚠️  PLANTILLA EDITABLE: el reparto exacto de grupos y los horarios son una
--     base de desarrollo. La app permite que cualquier usuario corrija equipos,
--     cruces y resultados desde el panel /resultados, así que se ajusta en vivo
--     contra el calendario oficial FIFA.
--
-- Idempotente: no hace nada si ya hay partidos cargados.
-- ============================================================================

DO $$
DECLARE
  group_letters TEXT[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];

  names TEXT[] := ARRAY[
    'México','Croacia','Corea del Sur','Ghana',
    'Canadá','Bélgica','Ecuador','Catar',
    'Estados Unidos','Países Bajos','Senegal','Arabia Saudí',
    'Argentina','Japón','Nigeria','Australia',
    'Francia','Dinamarca','Egipto','Costa Rica',
    'Brasil','Suiza','Camerún','Irán',
    'España','Uruguay','Costa de Marfil','Nueva Zelanda',
    'Inglaterra','Colombia','Marruecos','Panamá',
    'Portugal','Suecia','Túnez','Jamaica',
    'Alemania','Perú','Argelia','Honduras',
    'Italia','Chile','Sudáfrica','Eslovenia',
    'Polonia','Serbia','Malí','Uzbekistán'
  ];

  codes TEXT[] := ARRAY[
    'MEX','CRO','KOR','GHA',
    'CAN','BEL','ECU','QAT',
    'USA','NED','SEN','KSA',
    'ARG','JPN','NGA','AUS',
    'FRA','DEN','EGY','CRC',
    'BRA','SUI','CMR','IRN',
    'ESP','URU','CIV','NZL',
    'ENG','COL','MAR','PAN',
    'POR','SWE','TUN','JAM',
    'GER','PER','ALG','HON',
    'ITA','CHI','RSA','SVN',
    'POL','SRB','MLI','UZB'
  ];

  flags TEXT[] := ARRAY[
    '🇲🇽','🇭🇷','🇰🇷','🇬🇭',
    '🇨🇦','🇧🇪','🇪🇨','🇶🇦',
    '🇺🇸','🇳🇱','🇸🇳','🇸🇦',
    '🇦🇷','🇯🇵','🇳🇬','🇦🇺',
    '🇫🇷','🇩🇰','🇪🇬','🇨🇷',
    '🇧🇷','🇨🇭','🇨🇲','🇮🇷',
    '🇪🇸','🇺🇾','🇨🇮','🇳🇿',
    '🇬🇧','🇨🇴','🇲🇦','🇵🇦',
    '🇵🇹','🇸🇪','🇹🇳','🇯🇲',
    '🇩🇪','🇵🇪','🇩🇿','🇭🇳',
    '🇮🇹','🇨🇱','🇿🇦','🇸🇮',
    '🇵🇱','🇷🇸','🇲🇱','🇺🇿'
  ];

  -- Round-robin de 4 equipos (posiciones 1–4): 6 partidos.
  pat_h INT[] := ARRAY[1,3,1,4,4,2];
  pat_a INT[] := ARRAY[2,4,3,2,1,3];

  base_group TIMESTAMPTZ := '2026-06-11 16:00:00+00';
  base_ko    TIMESTAMPTZ := '2026-06-28 18:00:00+00';

  gi INT; j INT; mi INT; idx INT; k INT;
  team_ids UUID[];
  new_id UUID;
  mnum INT := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.matches) THEN
    RAISE NOTICE 'PorrApp seed: ya hay partidos cargados, no se hace nada.';
    RETURN;
  END IF;

  -- ---- Equipos + partidos de grupos ----
  FOR gi IN 0..11 LOOP
    team_ids := ARRAY[]::UUID[];
    FOR j IN 1..4 LOOP
      idx := gi * 4 + j;
      INSERT INTO public.teams (name, code, group_letter, flag_emoji)
      VALUES (names[idx], codes[idx], group_letters[gi + 1], flags[idx])
      RETURNING id INTO new_id;
      team_ids := array_append(team_ids, new_id);
    END LOOP;

    FOR mi IN 1..6 LOOP
      mnum := mnum + 1;
      INSERT INTO public.matches
        (match_number, stage, group_letter, home_team_id, away_team_id, kickoff_at)
      VALUES (
        mnum, 'group', group_letters[gi + 1],
        team_ids[pat_h[mi]], team_ids[pat_a[mi]],
        base_group + ((mnum - 1) * INTERVAL '6 hours')
      );
    END LOOP;
  END LOOP;

  -- ---- Eliminatorias (equipos TBD, etiquetas de cruce) ----
  -- Dieciseisavos (R32): 16 partidos (mnum 73–88)
  FOR k IN 1..16 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r32',
      'Clasificado grupos #' || (2 * k - 1),
      'Clasificado grupos #' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  -- Octavos (R16): 8 partidos (mnum 89–96)
  FOR k IN 1..8 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r16',
      'Ganador R32-' || (2 * k - 1),
      'Ganador R32-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  -- Cuartos (QF): 4 partidos (mnum 97–100)
  FOR k IN 1..4 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'qf',
      'Ganador R16-' || (2 * k - 1),
      'Ganador R16-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  -- Semifinales (SF): 2 partidos (mnum 101–102)
  FOR k IN 1..2 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'sf',
      'Ganador QF-' || (2 * k - 1),
      'Ganador QF-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  -- Tercer puesto (mnum 103)
  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'third', 'Perdedor SF-1', 'Perdedor SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  -- Final (mnum 104)
  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'final', 'Ganador SF-1', 'Ganador SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  RAISE NOTICE 'PorrApp seed completo: 48 equipos, % partidos.', mnum;
END $$;

