-- PorrApp — schema completo (001→020). Pegar en el SQL Editor de Supabase. Idempotente.

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
-- Carga inicial del Mundial 2026: 48 selecciones en los 12 grupos OFICIALES
-- (sorteo dic-2025), 72 partidos de fase de grupos (round-robin) y 32 de
-- eliminatorias.
--
-- Equipos por grupo en el orden del calendario oficial, de modo que el patrón
-- round-robin reproduce las jornadas reales (J1 del grupo A = México–Sudáfrica
-- y Corea–Rep. Checa; última del J = Argentina–Jordania).
--
-- ⚠️  Las HORAS de kickoff son una plantilla (se reparten por el torneo). Los
--     cruces y equipos son los oficiales. Cualquier usuario puede ajustar
--     horarios, definir cruces de eliminatorias y cargar resultados desde
--     /resultados.
--
-- Idempotente: no hace nada si ya hay partidos cargados.
-- ============================================================================

DO $$
DECLARE
  group_letters TEXT[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];

  names TEXT[] := ARRAY[
    'México','Sudáfrica','Corea del Sur','República Checa',
    'Canadá','Bosnia y Herzegovina','Catar','Suiza',
    'Brasil','Marruecos','Haití','Escocia',
    'Estados Unidos','Paraguay','Australia','Turquía',
    'Alemania','Curazao','Costa de Marfil','Ecuador',
    'Países Bajos','Japón','Suecia','Túnez',
    'Bélgica','Egipto','Irán','Nueva Zelanda',
    'España','Cabo Verde','Arabia Saudí','Uruguay',
    'Francia','Senegal','Irak','Noruega',
    'Argentina','Argelia','Austria','Jordania',
    'Portugal','RD Congo','Uzbekistán','Colombia',
    'Inglaterra','Croacia','Ghana','Panamá'
  ];

  codes TEXT[] := ARRAY[
    'MEX','RSA','KOR','CZE',
    'CAN','BIH','QAT','SUI',
    'BRA','MAR','HAI','SCO',
    'USA','PAR','AUS','TUR',
    'GER','CUW','CIV','ECU',
    'NED','JPN','SWE','TUN',
    'BEL','EGY','IRN','NZL',
    'ESP','CPV','KSA','URU',
    'FRA','SEN','IRQ','NOR',
    'ARG','ALG','AUT','JOR',
    'POR','COD','UZB','COL',
    'ENG','CRO','GHA','PAN'
  ];

  flags TEXT[] := ARRAY[
    '🇲🇽','🇿🇦','🇰🇷','🇨🇿',
    '🇨🇦','🇧🇦','🇶🇦','🇨🇭',
    '🇧🇷','🇲🇦','🇭🇹','🏴󠁧󠁢󠁳󠁣󠁴󠁿',
    '🇺🇸','🇵🇾','🇦🇺','🇹🇷',
    '🇩🇪','🇨🇼','🇨🇮','🇪🇨',
    '🇳🇱','🇯🇵','🇸🇪','🇹🇳',
    '🇧🇪','🇪🇬','🇮🇷','🇳🇿',
    '🇪🇸','🇨🇻','🇸🇦','🇺🇾',
    '🇫🇷','🇸🇳','🇮🇶','🇳🇴',
    '🇦🇷','🇩🇿','🇦🇹','🇯🇴',
    '🇵🇹','🇨🇩','🇺🇿','🇨🇴',
    '🏴󠁧󠁢󠁥󠁮󠁧󠁿','🇭🇷','🇬🇭','🇵🇦'
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
  FOR k IN 1..16 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r32',
      'Clasificado grupos #' || (2 * k - 1),
      'Clasificado grupos #' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..8 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r16',
      'Ganador R32-' || (2 * k - 1),
      'Ganador R32-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..4 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'qf',
      'Ganador R16-' || (2 * k - 1),
      'Ganador R16-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  FOR k IN 1..2 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'sf',
      'Ganador QF-' || (2 * k - 1),
      'Ganador QF-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'third', 'Perdedor SF-1', 'Perdedor SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'final', 'Ganador SF-1', 'Ganador SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  RAISE NOTICE 'PorrApp seed completo: 48 equipos, % partidos.', mnum;
END $$;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  007_reseed_fixture.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 007_reseed_fixture
-- Reemplaza el fixture de plantilla por los 12 grupos OFICIALES del Mundial
-- 2026 (sorteo dic-2025). Para bases ya sembradas con 006 antiguo.
--
-- ⚠️  Borra todos los partidos y equipos y los recarga. Esto elimina en cascada
--     los pronósticos y resultados ya cargados (datos de prueba). Los macro
--     picks que apunten a equipos quedan a NULL.
--     Ejecutar SOLO durante la puesta a punto, antes de jugar en serio.
-- ============================================================================

DELETE FROM public.matches;
DELETE FROM public.teams;

DO $$
DECLARE
  group_letters TEXT[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];

  names TEXT[] := ARRAY[
    'México','Sudáfrica','Corea del Sur','República Checa',
    'Canadá','Bosnia y Herzegovina','Catar','Suiza',
    'Brasil','Marruecos','Haití','Escocia',
    'Estados Unidos','Paraguay','Australia','Turquía',
    'Alemania','Curazao','Costa de Marfil','Ecuador',
    'Países Bajos','Japón','Suecia','Túnez',
    'Bélgica','Egipto','Irán','Nueva Zelanda',
    'España','Cabo Verde','Arabia Saudí','Uruguay',
    'Francia','Senegal','Irak','Noruega',
    'Argentina','Argelia','Austria','Jordania',
    'Portugal','RD Congo','Uzbekistán','Colombia',
    'Inglaterra','Croacia','Ghana','Panamá'
  ];

  codes TEXT[] := ARRAY[
    'MEX','RSA','KOR','CZE',
    'CAN','BIH','QAT','SUI',
    'BRA','MAR','HAI','SCO',
    'USA','PAR','AUS','TUR',
    'GER','CUW','CIV','ECU',
    'NED','JPN','SWE','TUN',
    'BEL','EGY','IRN','NZL',
    'ESP','CPV','KSA','URU',
    'FRA','SEN','IRQ','NOR',
    'ARG','ALG','AUT','JOR',
    'POR','COD','UZB','COL',
    'ENG','CRO','GHA','PAN'
  ];

  flags TEXT[] := ARRAY[
    '🇲🇽','🇿🇦','🇰🇷','🇨🇿',
    '🇨🇦','🇧🇦','🇶🇦','🇨🇭',
    '🇧🇷','🇲🇦','🇭🇹','🏴󠁧󠁢󠁳󠁣󠁴󠁿',
    '🇺🇸','🇵🇾','🇦🇺','🇹🇷',
    '🇩🇪','🇨🇼','🇨🇮','🇪🇨',
    '🇳🇱','🇯🇵','🇸🇪','🇹🇳',
    '🇧🇪','🇪🇬','🇮🇷','🇳🇿',
    '🇪🇸','🇨🇻','🇸🇦','🇺🇾',
    '🇫🇷','🇸🇳','🇮🇶','🇳🇴',
    '🇦🇷','🇩🇿','🇦🇹','🇯🇴',
    '🇵🇹','🇨🇩','🇺🇿','🇨🇴',
    '🏴󠁧󠁢󠁥󠁮󠁧󠁿','🇭🇷','🇬🇭','🇵🇦'
  ];

  pat_h INT[] := ARRAY[1,3,1,4,4,2];
  pat_a INT[] := ARRAY[2,4,3,2,1,3];

  base_group TIMESTAMPTZ := '2026-06-11 16:00:00+00';
  base_ko    TIMESTAMPTZ := '2026-06-28 18:00:00+00';

  gi INT; j INT; mi INT; idx INT; k INT;
  team_ids UUID[];
  new_id UUID;
  mnum INT := 0;
BEGIN
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

  FOR k IN 1..16 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r32',
      'Clasificado grupos #' || (2 * k - 1),
      'Clasificado grupos #' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..8 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r16',
      'Ganador R32-' || (2 * k - 1),
      'Ganador R32-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..4 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'qf',
      'Ganador R16-' || (2 * k - 1),
      'Ganador R16-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  FOR k IN 1..2 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'sf',
      'Ganador QF-' || (2 * k - 1),
      'Ganador QF-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'third', 'Perdedor SF-1', 'Perdedor SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'final', 'Ganador SF-1', 'Ganador SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  RAISE NOTICE 'PorrApp reseed completo: 48 equipos, % partidos.', mnum;
END $$;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  008_real_fixture.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 008_real_fixture
-- Fixture OFICIAL del Mundial 2026 (FIFA, calendario definitivo 6-dic-2025).
-- Autocontenida: fija los 48 equipos y reconstruye los 104 partidos con sede,
-- match_number oficial y kickoff en UTC (la fuente da horarios en ET = UTC-4).
-- Generada desde fixture.json por scripts/gen-008.js — no editar a mano.
--
-- ⚠️  Borra equipos y partidos y los recarga (elimina en cascada pronósticos
--     y resultados de prueba). Ejecutar durante la puesta a punto.
-- ============================================================================

ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS venue TEXT;

DELETE FROM public.matches;
DELETE FROM public.teams;

-- 48 selecciones
INSERT INTO public.teams (name, code, group_letter, flag_emoji) VALUES
  ('México', 'MEX', 'A', '🇲🇽'),
  ('Sudáfrica', 'RSA', 'A', '🇿🇦'),
  ('Corea del Sur', 'KOR', 'A', '🇰🇷'),
  ('República Checa', 'CZE', 'A', '🇨🇿'),
  ('Canadá', 'CAN', 'B', '🇨🇦'),
  ('Bosnia y Herzegovina', 'BIH', 'B', '🇧🇦'),
  ('Catar', 'QAT', 'B', '🇶🇦'),
  ('Suiza', 'SUI', 'B', '🇨🇭'),
  ('Brasil', 'BRA', 'C', '🇧🇷'),
  ('Marruecos', 'MAR', 'C', '🇲🇦'),
  ('Haití', 'HAI', 'C', '🇭🇹'),
  ('Escocia', 'SCO', 'C', '🏴󠁧󠁢󠁳󠁣󠁴󠁿'),
  ('Estados Unidos', 'USA', 'D', '🇺🇸'),
  ('Paraguay', 'PAR', 'D', '🇵🇾'),
  ('Australia', 'AUS', 'D', '🇦🇺'),
  ('Turquía', 'TUR', 'D', '🇹🇷'),
  ('Alemania', 'GER', 'E', '🇩🇪'),
  ('Curazao', 'CUW', 'E', '🇨🇼'),
  ('Costa de Marfil', 'CIV', 'E', '🇨🇮'),
  ('Ecuador', 'ECU', 'E', '🇪🇨'),
  ('Países Bajos', 'NED', 'F', '🇳🇱'),
  ('Japón', 'JPN', 'F', '🇯🇵'),
  ('Suecia', 'SWE', 'F', '🇸🇪'),
  ('Túnez', 'TUN', 'F', '🇹🇳'),
  ('Bélgica', 'BEL', 'G', '🇧🇪'),
  ('Egipto', 'EGY', 'G', '🇪🇬'),
  ('Irán', 'IRN', 'G', '🇮🇷'),
  ('Nueva Zelanda', 'NZL', 'G', '🇳🇿'),
  ('España', 'ESP', 'H', '🇪🇸'),
  ('Cabo Verde', 'CPV', 'H', '🇨🇻'),
  ('Arabia Saudí', 'KSA', 'H', '🇸🇦'),
  ('Uruguay', 'URU', 'H', '🇺🇾'),
  ('Francia', 'FRA', 'I', '🇫🇷'),
  ('Senegal', 'SEN', 'I', '🇸🇳'),
  ('Irak', 'IRQ', 'I', '🇮🇶'),
  ('Noruega', 'NOR', 'I', '🇳🇴'),
  ('Argentina', 'ARG', 'J', '🇦🇷'),
  ('Argelia', 'ALG', 'J', '🇩🇿'),
  ('Austria', 'AUT', 'J', '🇦🇹'),
  ('Jordania', 'JOR', 'J', '🇯🇴'),
  ('Portugal', 'POR', 'K', '🇵🇹'),
  ('RD Congo', 'COD', 'K', '🇨🇩'),
  ('Uzbekistán', 'UZB', 'K', '🇺🇿'),
  ('Colombia', 'COL', 'K', '🇨🇴'),
  ('Inglaterra', 'ENG', 'L', '🏴󠁧󠁢󠁥󠁮󠁧󠁿'),
  ('Croacia', 'CRO', 'L', '🇭🇷'),
  ('Ghana', 'GHA', 'L', '🇬🇭'),
  ('Panamá', 'PAN', 'L', '🇵🇦');

-- 72 partidos de fase de grupos (equipos por código, kickoff UTC, sede)
INSERT INTO public.matches (match_number, stage, group_letter, home_team_id, away_team_id, kickoff_at, venue) VALUES
  (1, 'group', 'A', (SELECT id FROM public.teams WHERE code='MEX'), (SELECT id FROM public.teams WHERE code='RSA'), '2026-06-11T19:00:00.000Z', 'Estadio Ciudad de México'),
  (2, 'group', 'A', (SELECT id FROM public.teams WHERE code='KOR'), (SELECT id FROM public.teams WHERE code='CZE'), '2026-06-12T02:00:00.000Z', 'Estadio Guadalajara'),
  (3, 'group', 'B', (SELECT id FROM public.teams WHERE code='CAN'), (SELECT id FROM public.teams WHERE code='BIH'), '2026-06-12T19:00:00.000Z', 'Estadio Toronto'),
  (4, 'group', 'D', (SELECT id FROM public.teams WHERE code='USA'), (SELECT id FROM public.teams WHERE code='PAR'), '2026-06-13T01:00:00.000Z', 'Estadio Los Ángeles'),
  (5, 'group', 'B', (SELECT id FROM public.teams WHERE code='QAT'), (SELECT id FROM public.teams WHERE code='SUI'), '2026-06-13T19:00:00.000Z', 'Estadio Bahía de San Francisco'),
  (6, 'group', 'C', (SELECT id FROM public.teams WHERE code='BRA'), (SELECT id FROM public.teams WHERE code='MAR'), '2026-06-13T22:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (7, 'group', 'C', (SELECT id FROM public.teams WHERE code='HAI'), (SELECT id FROM public.teams WHERE code='SCO'), '2026-06-14T01:00:00.000Z', 'Estadio Boston'),
  (8, 'group', 'D', (SELECT id FROM public.teams WHERE code='AUS'), (SELECT id FROM public.teams WHERE code='TUR'), '2026-06-13T04:00:00.000Z', 'Estadio BC Place Vancouver'),
  (9, 'group', 'E', (SELECT id FROM public.teams WHERE code='GER'), (SELECT id FROM public.teams WHERE code='CUW'), '2026-06-14T17:00:00.000Z', 'Estadio Houston'),
  (10, 'group', 'F', (SELECT id FROM public.teams WHERE code='NED'), (SELECT id FROM public.teams WHERE code='JPN'), '2026-06-14T20:00:00.000Z', 'Estadio Dallas'),
  (11, 'group', 'E', (SELECT id FROM public.teams WHERE code='CIV'), (SELECT id FROM public.teams WHERE code='ECU'), '2026-06-14T23:00:00.000Z', 'Estadio Filadelfia'),
  (12, 'group', 'F', (SELECT id FROM public.teams WHERE code='SWE'), (SELECT id FROM public.teams WHERE code='TUN'), '2026-06-15T02:00:00.000Z', 'Estadio Monterrey'),
  (13, 'group', 'H', (SELECT id FROM public.teams WHERE code='ESP'), (SELECT id FROM public.teams WHERE code='CPV'), '2026-06-15T16:00:00.000Z', 'Estadio Atlanta'),
  (14, 'group', 'G', (SELECT id FROM public.teams WHERE code='BEL'), (SELECT id FROM public.teams WHERE code='EGY'), '2026-06-15T19:00:00.000Z', 'Estadio Seattle'),
  (15, 'group', 'H', (SELECT id FROM public.teams WHERE code='KSA'), (SELECT id FROM public.teams WHERE code='URU'), '2026-06-15T22:00:00.000Z', 'Estadio Miami'),
  (16, 'group', 'G', (SELECT id FROM public.teams WHERE code='IRN'), (SELECT id FROM public.teams WHERE code='NZL'), '2026-06-16T01:00:00.000Z', 'Estadio Los Ángeles'),
  (17, 'group', 'I', (SELECT id FROM public.teams WHERE code='FRA'), (SELECT id FROM public.teams WHERE code='SEN'), '2026-06-16T19:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (18, 'group', 'I', (SELECT id FROM public.teams WHERE code='IRQ'), (SELECT id FROM public.teams WHERE code='NOR'), '2026-06-16T22:00:00.000Z', 'Estadio Boston'),
  (19, 'group', 'J', (SELECT id FROM public.teams WHERE code='ARG'), (SELECT id FROM public.teams WHERE code='ALG'), '2026-06-17T01:00:00.000Z', 'Estadio Kansas City'),
  (20, 'group', 'J', (SELECT id FROM public.teams WHERE code='AUT'), (SELECT id FROM public.teams WHERE code='JOR'), '2026-06-16T04:00:00.000Z', 'Estadio Bahía de San Francisco'),
  (21, 'group', 'K', (SELECT id FROM public.teams WHERE code='POR'), (SELECT id FROM public.teams WHERE code='COD'), '2026-06-17T17:00:00.000Z', 'Estadio Houston'),
  (22, 'group', 'L', (SELECT id FROM public.teams WHERE code='ENG'), (SELECT id FROM public.teams WHERE code='CRO'), '2026-06-17T20:00:00.000Z', 'Estadio Dallas'),
  (23, 'group', 'L', (SELECT id FROM public.teams WHERE code='GHA'), (SELECT id FROM public.teams WHERE code='PAN'), '2026-06-17T23:00:00.000Z', 'Estadio Toronto'),
  (24, 'group', 'K', (SELECT id FROM public.teams WHERE code='UZB'), (SELECT id FROM public.teams WHERE code='COL'), '2026-06-18T02:00:00.000Z', 'Estadio Ciudad de México'),
  (25, 'group', 'A', (SELECT id FROM public.teams WHERE code='CZE'), (SELECT id FROM public.teams WHERE code='RSA'), '2026-06-18T16:00:00.000Z', 'Estadio Atlanta'),
  (26, 'group', 'B', (SELECT id FROM public.teams WHERE code='SUI'), (SELECT id FROM public.teams WHERE code='BIH'), '2026-06-18T19:00:00.000Z', 'Estadio Los Ángeles'),
  (27, 'group', 'B', (SELECT id FROM public.teams WHERE code='CAN'), (SELECT id FROM public.teams WHERE code='QAT'), '2026-06-18T22:00:00.000Z', 'Estadio BC Place Vancouver'),
  (28, 'group', 'A', (SELECT id FROM public.teams WHERE code='MEX'), (SELECT id FROM public.teams WHERE code='KOR'), '2026-06-19T01:00:00.000Z', 'Estadio Guadalajara'),
  (29, 'group', 'D', (SELECT id FROM public.teams WHERE code='USA'), (SELECT id FROM public.teams WHERE code='AUS'), '2026-06-19T19:00:00.000Z', 'Estadio Seattle'),
  (30, 'group', 'C', (SELECT id FROM public.teams WHERE code='SCO'), (SELECT id FROM public.teams WHERE code='MAR'), '2026-06-19T22:00:00.000Z', 'Estadio Boston'),
  (31, 'group', 'C', (SELECT id FROM public.teams WHERE code='BRA'), (SELECT id FROM public.teams WHERE code='HAI'), '2026-06-20T01:00:00.000Z', 'Estadio Filadelfia'),
  (32, 'group', 'D', (SELECT id FROM public.teams WHERE code='TUR'), (SELECT id FROM public.teams WHERE code='PAR'), '2026-06-19T04:00:00.000Z', 'Estadio Bahía de San Francisco'),
  (33, 'group', 'F', (SELECT id FROM public.teams WHERE code='NED'), (SELECT id FROM public.teams WHERE code='SWE'), '2026-06-20T17:00:00.000Z', 'Estadio Houston'),
  (34, 'group', 'E', (SELECT id FROM public.teams WHERE code='GER'), (SELECT id FROM public.teams WHERE code='CIV'), '2026-06-20T20:00:00.000Z', 'Estadio Toronto'),
  (35, 'group', 'E', (SELECT id FROM public.teams WHERE code='ECU'), (SELECT id FROM public.teams WHERE code='CUW'), '2026-06-21T02:00:00.000Z', 'Estadio Kansas City'),
  (36, 'group', 'F', (SELECT id FROM public.teams WHERE code='TUN'), (SELECT id FROM public.teams WHERE code='JPN'), '2026-06-20T04:00:00.000Z', 'Estadio Monterrey'),
  (37, 'group', 'H', (SELECT id FROM public.teams WHERE code='ESP'), (SELECT id FROM public.teams WHERE code='KSA'), '2026-06-21T16:00:00.000Z', 'Estadio Atlanta'),
  (38, 'group', 'G', (SELECT id FROM public.teams WHERE code='BEL'), (SELECT id FROM public.teams WHERE code='IRN'), '2026-06-21T19:00:00.000Z', 'Estadio Los Ángeles'),
  (39, 'group', 'H', (SELECT id FROM public.teams WHERE code='URU'), (SELECT id FROM public.teams WHERE code='CPV'), '2026-06-21T22:00:00.000Z', 'Estadio Miami'),
  (40, 'group', 'G', (SELECT id FROM public.teams WHERE code='NZL'), (SELECT id FROM public.teams WHERE code='EGY'), '2026-06-22T01:00:00.000Z', 'Estadio BC Place Vancouver'),
  (41, 'group', 'J', (SELECT id FROM public.teams WHERE code='ARG'), (SELECT id FROM public.teams WHERE code='AUT'), '2026-06-22T17:00:00.000Z', 'Estadio Dallas'),
  (42, 'group', 'I', (SELECT id FROM public.teams WHERE code='FRA'), (SELECT id FROM public.teams WHERE code='IRQ'), '2026-06-22T21:00:00.000Z', 'Estadio Filadelfia'),
  (43, 'group', 'I', (SELECT id FROM public.teams WHERE code='NOR'), (SELECT id FROM public.teams WHERE code='SEN'), '2026-06-23T00:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (44, 'group', 'J', (SELECT id FROM public.teams WHERE code='JOR'), (SELECT id FROM public.teams WHERE code='ALG'), '2026-06-23T03:00:00.000Z', 'Estadio Bahía de San Francisco Bay'),
  (45, 'group', 'K', (SELECT id FROM public.teams WHERE code='POR'), (SELECT id FROM public.teams WHERE code='UZB'), '2026-06-23T17:00:00.000Z', 'Estadio Houston'),
  (46, 'group', 'L', (SELECT id FROM public.teams WHERE code='ENG'), (SELECT id FROM public.teams WHERE code='GHA'), '2026-06-23T20:00:00.000Z', 'Estadio Boston'),
  (47, 'group', 'L', (SELECT id FROM public.teams WHERE code='PAN'), (SELECT id FROM public.teams WHERE code='CRO'), '2026-06-23T23:00:00.000Z', 'Estadio Toronto'),
  (48, 'group', 'K', (SELECT id FROM public.teams WHERE code='COL'), (SELECT id FROM public.teams WHERE code='COD'), '2026-06-24T02:00:00.000Z', 'Estadio Guadalajara'),
  (49, 'group', 'B', (SELECT id FROM public.teams WHERE code='SUI'), (SELECT id FROM public.teams WHERE code='CAN'), '2026-06-24T19:00:00.000Z', 'Estadio BC Place Vancouver'),
  (50, 'group', 'B', (SELECT id FROM public.teams WHERE code='BIH'), (SELECT id FROM public.teams WHERE code='QAT'), '2026-06-24T19:00:00.000Z', 'Estadio Seattle'),
  (51, 'group', 'C', (SELECT id FROM public.teams WHERE code='SCO'), (SELECT id FROM public.teams WHERE code='BRA'), '2026-06-24T22:00:00.000Z', 'Estadio Miami'),
  (52, 'group', 'C', (SELECT id FROM public.teams WHERE code='MAR'), (SELECT id FROM public.teams WHERE code='HAI'), '2026-06-24T22:00:00.000Z', 'Estadio Atlanta'),
  (53, 'group', 'A', (SELECT id FROM public.teams WHERE code='CZE'), (SELECT id FROM public.teams WHERE code='MEX'), '2026-06-25T01:00:00.000Z', 'Estadio Ciudad de México'),
  (54, 'group', 'A', (SELECT id FROM public.teams WHERE code='RSA'), (SELECT id FROM public.teams WHERE code='KOR'), '2026-06-25T01:00:00.000Z', 'Estadio Monterrey'),
  (55, 'group', 'E', (SELECT id FROM public.teams WHERE code='CUW'), (SELECT id FROM public.teams WHERE code='CIV'), '2026-06-25T20:00:00.000Z', 'Estadio Filadelfia'),
  (56, 'group', 'E', (SELECT id FROM public.teams WHERE code='ECU'), (SELECT id FROM public.teams WHERE code='GER'), '2026-06-25T20:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (57, 'group', 'F', (SELECT id FROM public.teams WHERE code='JPN'), (SELECT id FROM public.teams WHERE code='SWE'), '2026-06-25T23:00:00.000Z', 'Estadio Dallas'),
  (58, 'group', 'F', (SELECT id FROM public.teams WHERE code='TUN'), (SELECT id FROM public.teams WHERE code='NED'), '2026-06-25T23:00:00.000Z', 'Estadio Kansas City'),
  (59, 'group', 'D', (SELECT id FROM public.teams WHERE code='TUR'), (SELECT id FROM public.teams WHERE code='USA'), '2026-06-26T02:00:00.000Z', 'Estadio Los Ángeles'),
  (60, 'group', 'D', (SELECT id FROM public.teams WHERE code='PAR'), (SELECT id FROM public.teams WHERE code='AUS'), '2026-06-26T02:00:00.000Z', 'Estadio Bahía de San Francisco'),
  (61, 'group', 'I', (SELECT id FROM public.teams WHERE code='NOR'), (SELECT id FROM public.teams WHERE code='FRA'), '2026-06-26T19:00:00.000Z', 'Estadio Boston'),
  (62, 'group', 'I', (SELECT id FROM public.teams WHERE code='SEN'), (SELECT id FROM public.teams WHERE code='IRQ'), '2026-06-26T19:00:00.000Z', 'Estadio Toronto'),
  (63, 'group', 'H', (SELECT id FROM public.teams WHERE code='CPV'), (SELECT id FROM public.teams WHERE code='KSA'), '2026-06-27T00:00:00.000Z', 'Estadio Houston'),
  (64, 'group', 'H', (SELECT id FROM public.teams WHERE code='URU'), (SELECT id FROM public.teams WHERE code='ESP'), '2026-06-27T00:00:00.000Z', 'Estadio Guadalajara'),
  (65, 'group', 'G', (SELECT id FROM public.teams WHERE code='EGY'), (SELECT id FROM public.teams WHERE code='IRN'), '2026-06-27T03:00:00.000Z', 'Estadio Seattle'),
  (66, 'group', 'G', (SELECT id FROM public.teams WHERE code='NZL'), (SELECT id FROM public.teams WHERE code='BEL'), '2026-06-27T03:00:00.000Z', 'Estadio BC Place Vancouver'),
  (67, 'group', 'L', (SELECT id FROM public.teams WHERE code='PAN'), (SELECT id FROM public.teams WHERE code='ENG'), '2026-06-27T21:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (68, 'group', 'L', (SELECT id FROM public.teams WHERE code='CRO'), (SELECT id FROM public.teams WHERE code='GHA'), '2026-06-27T21:00:00.000Z', 'Estadio Filadelfia'),
  (69, 'group', 'K', (SELECT id FROM public.teams WHERE code='COL'), (SELECT id FROM public.teams WHERE code='POR'), '2026-06-27T23:30:00.000Z', 'Estadio Miami'),
  (70, 'group', 'K', (SELECT id FROM public.teams WHERE code='COD'), (SELECT id FROM public.teams WHERE code='UZB'), '2026-06-27T23:30:00.000Z', 'Estadio Atlanta'),
  (71, 'group', 'J', (SELECT id FROM public.teams WHERE code='ALG'), (SELECT id FROM public.teams WHERE code='AUT'), '2026-06-28T02:00:00.000Z', 'Estadio Kansas City'),
  (72, 'group', 'J', (SELECT id FROM public.teams WHERE code='JOR'), (SELECT id FROM public.teams WHERE code='ARG'), '2026-06-28T02:00:00.000Z', 'Estadio Dallas');

-- 32 partidos de eliminatorias (equipos TBD: etiquetas oficiales de cruce)
INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at, venue) VALUES
  (73, 'r32', '2º Grupo A', '2º Grupo B', '2026-06-28T20:00:00.000Z', 'Estadio Los Ángeles'),
  (74, 'r32', '1º Grupo E', '3º Grupo A/B/C/D/F', '2026-06-29T20:00:00.000Z', 'Estadio Boston'),
  (75, 'r32', '1º Grupo F', '2º Grupo C', '2026-06-29T20:00:00.000Z', 'Estadio Monterrey'),
  (76, 'r32', '1º Grupo C', '2º Grupo F', '2026-06-29T20:00:00.000Z', 'Estadio Houston'),
  (77, 'r32', '1º Grupo I', '3º Grupo C/D/F/G/H', '2026-06-30T20:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (78, 'r32', '2º Grupo E', '2º Grupo I', '2026-06-30T20:00:00.000Z', 'Estadio Dallas'),
  (79, 'r32', '1º Grupo A', '3º Grupo C/E/F/H/I', '2026-06-30T20:00:00.000Z', 'Estadio Ciudad de México'),
  (80, 'r32', '1º Grupo L', '3º Grupo E/H/I/J/K', '2026-07-01T20:00:00.000Z', 'Estadio Atlanta'),
  (81, 'r32', '1º Grupo D', '3º Grupo B/E/F/I/J', '2026-07-01T20:00:00.000Z', 'Estadio Bahía de San Francisco'),
  (82, 'r32', '1º Grupo G', '3º Grupo A/E/H/I/J', '2026-07-01T20:00:00.000Z', 'Estadio Seattle'),
  (83, 'r32', '2º Grupo K', '2º Grupo L', '2026-07-02T20:00:00.000Z', 'Estadio Toronto'),
  (84, 'r32', '1º Grupo H', '2º Grupo J', '2026-07-02T20:00:00.000Z', 'Estadio Los Ángeles'),
  (85, 'r32', '1º Grupo B', '3º Grupo E/F/G/I/J', '2026-07-02T20:00:00.000Z', 'Estadio BC Place Vancouver'),
  (86, 'r32', '1º Grupo J', '2º Grupo H', '2026-07-03T20:00:00.000Z', 'Estadio Miami'),
  (87, 'r32', '1º Grupo K', '3º Grupo D/E/I/J/L', '2026-07-03T20:00:00.000Z', 'Estadio Kansas City'),
  (88, 'r32', '2º Grupo D', '2º Grupo G', '2026-07-03T20:00:00.000Z', 'Estadio Dallas'),
  (89, 'r16', 'Ganador Partido 74', 'Ganador Partido 77', '2026-07-04T20:00:00.000Z', 'Estadio Filadelfia'),
  (90, 'r16', 'Ganador Partido 73', 'Ganador Partido 75', '2026-07-04T20:00:00.000Z', 'Estadio Houston'),
  (91, 'r16', 'Ganador Partido 76', 'Ganador Partido 78', '2026-07-05T20:00:00.000Z', 'Estadio Nueva York Nueva Jersey'),
  (92, 'r16', 'Ganador Partido 79', 'Ganador Partido 80', '2026-07-05T20:00:00.000Z', 'Estadio Ciudad de México'),
  (93, 'r16', 'Ganador Partido 83', 'Ganador Partido 84', '2026-07-06T20:00:00.000Z', 'Estadio Dallas'),
  (94, 'r16', 'Ganador Partido 81', 'Ganador Partido 82', '2026-07-06T20:00:00.000Z', 'Estadio Seattle'),
  (95, 'r16', 'Ganador Partido 86', 'Ganador Partido 88', '2026-07-07T20:00:00.000Z', 'Estadio Atlanta'),
  (96, 'r16', 'Ganador Partido 85', 'Ganador Partido 87', '2026-07-07T20:00:00.000Z', 'Estadio BC Place Vancouver'),
  (97, 'qf', 'Ganador Partido 89', 'Ganador Partido 90', '2026-07-09T20:00:00.000Z', 'Estadio Boston'),
  (98, 'qf', 'Ganador Partido 93', 'Ganador Partido 94', '2026-07-10T20:00:00.000Z', 'Estadio Los Ángeles'),
  (99, 'qf', 'Ganador Partido 91', 'Ganador Partido 92', '2026-07-11T20:00:00.000Z', 'Estadio Miami'),
  (100, 'qf', 'Ganador Partido 95', 'Ganador Partido 96', '2026-07-11T20:00:00.000Z', 'Estadio Kansas City'),
  (101, 'sf', 'Ganador Partido 97', 'Ganador Partido 98', '2026-07-14T20:00:00.000Z', 'Estadio Dallas'),
  (102, 'sf', 'Ganador Partido 99', 'Ganador Partido 100', '2026-07-15T20:00:00.000Z', 'Estadio Atlanta'),
  (103, 'third', 'Perdedor Partido 101', 'Perdedor Partido 102', '2026-07-18T20:00:00.000Z', 'Estadio Miami'),
  (104, 'final', 'Ganador Partido 101', 'Ganador Partido 102', '2026-07-19T20:00:00.000Z', 'Estadio Nueva York Nueva Jersey');



-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  009_phase_breakdown.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 009_phase_breakdown
-- Desglose de puntos por FASE para el ranking (exactos / aciertos / puntos por
-- usuario y por etapa). SECURITY DEFINER + restringido a miembros de la liga.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.league_phase_breakdown(p_league_id UUID)
RETURNS TABLE (
  user_id UUID,
  stage TEXT,
  exact_count INT,
  result_count INT,
  points INT
) AS $$
  SELECT
    lm.user_id,
    m.stage,
    SUM(CASE WHEN mp.home_score = m.home_score AND mp.away_score = m.away_score
             THEN 1 ELSE 0 END)::INT AS exact_count,
    SUM(CASE WHEN NOT (mp.home_score = m.home_score AND mp.away_score = m.away_score)
              AND sign(mp.home_score - mp.away_score) = sign(m.home_score - m.away_score)
             THEN 1 ELSE 0 END)::INT AS result_count,
    COALESCE(SUM(public.score_match(mp.home_score, mp.away_score, m.home_score, m.away_score)), 0)::INT AS points
  FROM public.league_members lm
  JOIN public.match_predictions mp ON mp.user_id = lm.user_id
  JOIN public.matches m ON m.id = mp.match_id AND m.status = 'finished'
  WHERE lm.league_id = p_league_id
    AND public.is_league_member(p_league_id, auth.uid())
  GROUP BY lm.user_id, m.stage;
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  010_chat.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 010_chat
-- Chat interno por liga. Solo miembros leen/escriben en su liga.
-- ============================================================================

CREATE TABLE IF NOT EXISTS league_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK (length(trim(body)) > 0 AND length(body) <= 2000),
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_league_messages_league
  ON league_messages(league_id, created_at);

ALTER TABLE league_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Messages readable by league members" ON league_messages;
DROP POLICY IF EXISTS "Members can post messages" ON league_messages;

CREATE POLICY "Messages readable by league members"
  ON league_messages FOR SELECT
  USING (public.is_league_member(league_id, auth.uid()));

CREATE POLICY "Members can post messages"
  ON league_messages FOR INSERT
  WITH CHECK (public.is_league_member(league_id, auth.uid()) AND auth.uid() = user_id);

-- Habilita Realtime (idempotente: ignora si ya está en la publicación)
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.league_messages;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  011_league_fee.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 011_league_fee
-- Cuota de entrada por liga (bote). Informativa: bote = cuota × nº miembros.
-- La edita el owner (la política UPDATE de leagues ya es owner-only).
-- ============================================================================

ALTER TABLE public.leagues
  ADD COLUMN IF NOT EXISTS entry_fee NUMERIC NOT NULL DEFAULT 0 CHECK (entry_fee >= 0);


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  012_group_positions.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 012_group_positions
-- Pronóstico de 1º y 2º de cada grupo. Acertar 1º = 3 pts, 2º = 2 pts.
-- El resultado real se deriva de la clasificación (solo grupos ya completos).
-- ============================================================================

CREATE TABLE IF NOT EXISTS group_position_predictions (
    user_id UUID NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
    group_letter TEXT NOT NULL,
    first_team_id UUID REFERENCES teams (id) ON DELETE SET NULL,
    second_team_id UUID REFERENCES teams (id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    PRIMARY KEY (user_id, group_letter)
);

ALTER TABLE group_position_predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own group picks or after start readable" ON group_position_predictions;

DROP POLICY IF EXISTS "Insert own group picks" ON group_position_predictions;

DROP POLICY IF EXISTS "Update own group picks" ON group_position_predictions;

CREATE POLICY "Own group picks or after start readable" ON group_position_predictions FOR
SELECT USING (
        auth.uid () = user_id
        OR public.tournament_started ()
    );

CREATE POLICY "Insert own group picks" ON group_position_predictions FOR INSERT
WITH
    CHECK (auth.uid () = user_id);

CREATE POLICY "Update own group picks" ON group_position_predictions
FOR UPDATE
    USING (auth.uid () = user_id);

-- Clasificación real por grupo (solo grupos con TODOS sus partidos finalizados).
CREATE OR REPLACE FUNCTION public.group_standings()
RETURNS TABLE (group_letter TEXT, team_id UUID, pos INT) AS $$
  WITH gm AS (
    SELECT m.group_letter AS gl, t.id AS team_id,
      CASE WHEN m.home_team_id = t.id THEN m.home_score ELSE m.away_score END AS gf,
      CASE WHEN m.home_team_id = t.id THEN m.away_score ELSE m.home_score END AS ga
    FROM public.matches m
    JOIN public.teams t ON t.id IN (m.home_team_id, m.away_team_id)
    WHERE m.stage = 'group' AND m.status = 'finished'
      AND m.home_score IS NOT NULL AND m.away_score IS NOT NULL
  ),
  agg AS (
    SELECT gl, team_id,
      SUM(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END) AS pts,
      SUM(gf - ga) AS dg,
      SUM(gf) AS gf_total
    FROM gm GROUP BY gl, team_id
  ),
  complete AS (
    SELECT group_letter AS gl
    FROM public.matches
    WHERE stage = 'group'
    GROUP BY group_letter
    HAVING count(*) = count(*) FILTER (WHERE status = 'finished')
  )
  SELECT a.gl, a.team_id,
    ROW_NUMBER() OVER (PARTITION BY a.gl ORDER BY a.pts DESC, a.dg DESC, a.gf_total DESC)::INT
  FROM agg a
  JOIN complete c ON c.gl = a.gl;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Puntos por acertar 1º/2º de grupo.
CREATE OR REPLACE FUNCTION public.group_position_points(p_user_id UUID)
RETURNS INT AS $$
  SELECT COALESCE(SUM(
    (CASE WHEN gp.first_team_id IS NOT NULL AND gp.first_team_id = s1.team_id THEN 3 ELSE 0 END) +
    (CASE WHEN gp.second_team_id IS NOT NULL AND gp.second_team_id = s2.team_id THEN 2 ELSE 0 END)
  ), 0)::INT
  FROM public.group_position_predictions gp
  LEFT JOIN public.group_standings() s1 ON s1.group_letter = gp.group_letter AND s1.pos = 1
  LEFT JOIN public.group_standings() s2 ON s2.group_letter = gp.group_letter AND s2.pos = 2
  WHERE gp.user_id = p_user_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Recalcula el ranking incluyendo macro + posiciones de grupo.
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
    (mp.total + public.macro_points(p.id) + public.group_position_points(p.id))::INT AS total_points,
    mp.total AS match_points,
    (public.macro_points(p.id) + public.group_position_points(p.id))::INT AS macro_points,
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  013_extra_breakdown.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 013_extra_breakdown
-- Puntos extra por miembro (picks de torneo + posiciones de grupo) para el
-- desglose del Ranking. Restringido a miembros de la liga.
-- ============================================================================

-- DROP previo: una versión posterior (018) añade más columnas; sin el DROP,
-- re-correr el schema falla con "cannot change return type of existing function".
DROP FUNCTION IF EXISTS public.league_extra_breakdown(UUID);
CREATE OR REPLACE FUNCTION public.league_extra_breakdown(p_league_id UUID)
RETURNS TABLE (
  user_id UUID,
  macro_pts INT,
  group_pts INT
) AS $$
  SELECT
    lm.user_id,
    public.macro_points(lm.user_id),
    public.group_position_points(lm.user_id)
  FROM public.league_members lm
  WHERE lm.league_id = p_league_id
    AND public.is_league_member(p_league_id, auth.uid());
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  014_players.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 014_players
-- Jugadores (para el pichichi de grupo). El grupo se deriva de su selección.
-- Tabla lista para sembrar; el pronóstico de goleador por grupo y su scoring
-- se añaden cuando esté cargado el listado.
-- ============================================================================

CREATE TABLE IF NOT EXISTS players (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_players_team ON players(team_id);

ALTER TABLE players ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Players readable by authenticated" ON players;
CREATE POLICY "Players readable by authenticated"
  ON players FOR SELECT USING (auth.uid() IS NOT NULL);


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  015_players_extra.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 015_players_extra
-- Amplía players con posición, dorsal y club (máxima info del scraper).
-- ============================================================================

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS position TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS shirt_number INT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS club TEXT;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  016_picks_lock.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 016_picks_lock
-- Los picks de torneo (campeón, goleador, 1º/2º de grupo) cierran 60 minutos
-- ANTES del primer partido, igual que el cierre por partido.
-- Redefine tournament_started(): las políticas RLS y la app la usan por nombre.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.tournament_started()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.matches
    WHERE NOW() >= kickoff_at - INTERVAL '60 minutes'
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  017_seed_players.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 017_seed_players
-- Plantillas del Mundial 2026 (Wikipedia, en.wikipedia 2026_FIFA_World_Cup_squads).
-- Generado por scripts/build-players.cjs — no editar a mano.
-- Idempotente: borra y recarga players.
-- ============================================================================

DELETE FROM public.players;

INSERT INTO public.players (name, team_id, position, shirt_number, club) VALUES
  ('Matěj Kovář', (SELECT id FROM public.teams WHERE code='CZE'), 'GK', 1, 'PSV Eindhoven'),
  ('David Zima', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 2, 'Slavia Prague'),
  ('Tomáš Holeš', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 3, 'Slavia Prague'),
  ('Robin Hranáč', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 4, 'TSG Hoffenheim'),
  ('Vladimír Coufal', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 5, 'TSG Hoffenheim'),
  ('Štěpán Chaloupek', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 6, 'Slavia Prague'),
  ('Ladislav Krejčí (captain)', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 7, 'Wolverhampton Wanderers'),
  ('Vladimír Darida', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 8, 'Hradec Králové'),
  ('Adam Hložek', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 9, 'TSG Hoffenheim'),
  ('Patrik Schick', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 10, 'Bayer Leverkusen'),
  ('Jan Kuchta', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 11, 'Sparta Prague'),
  ('Lukáš Červ', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 12, 'Viktoria Plzeň'),
  ('Mojmír Chytil', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 13, 'Slavia Prague'),
  ('David Jurásek', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 14, 'Slavia Prague'),
  ('Pavel Šulc', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 15, 'Lyon'),
  ('Jindřich Staněk', (SELECT id FROM public.teams WHERE code='CZE'), 'GK', 16, 'Slavia Prague'),
  ('Lukáš Provod', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 17, 'Slavia Prague'),
  ('Michal Sadílek', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 18, 'Slavia Prague'),
  ('Tomáš Chorý', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 19, 'Slavia Prague'),
  ('Jaroslav Zelený', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 20, 'Sparta Prague'),
  ('David Douděra', (SELECT id FROM public.teams WHERE code='CZE'), 'DF', 21, 'Slavia Prague'),
  ('Tomáš Souček', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 22, 'West Ham United'),
  ('Lukáš Horníček', (SELECT id FROM public.teams WHERE code='CZE'), 'GK', 23, 'Braga'),
  ('Alexandr Sojka', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 24, 'Viktoria Plzeň'),
  ('Hugo Sochůrek', (SELECT id FROM public.teams WHERE code='CZE'), 'MF', 25, 'Sparta Prague'),
  ('Denis Višinský', (SELECT id FROM public.teams WHERE code='CZE'), 'FW', 26, 'Viktoria Plzeň'),
  ('Raúl Rangel', (SELECT id FROM public.teams WHERE code='MEX'), 'GK', 1, 'Guadalajara'),
  ('Jorge Sánchez', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 2, 'PAOK'),
  ('César Montes', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 3, 'Lokomotiv Moscow'),
  ('Edson Álvarez (captain)', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 4, 'Fenerbahçe'),
  ('Johan Vásquez', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 5, 'Genoa'),
  ('Érik Lira', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 6, 'Cruz Azul'),
  ('Luis Romo', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 7, 'Guadalajara'),
  ('Álvaro Fidalgo', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 8, 'Real Betis'),
  ('Raúl Jiménez', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 9, 'Fulham'),
  ('Alexis Vega', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 10, 'Toluca'),
  ('Santiago Giménez', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 11, 'Milan'),
  ('Carlos Acevedo', (SELECT id FROM public.teams WHERE code='MEX'), 'GK', 12, 'Santos Laguna'),
  ('Guillermo Ochoa', (SELECT id FROM public.teams WHERE code='MEX'), 'GK', 13, 'AEL Limassol'),
  ('Armando González', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 14, 'Guadalajara'),
  ('Israel Reyes', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 15, 'América'),
  ('Julián Quiñones', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 16, 'Al-Qadsiah'),
  ('Orbelín Pineda', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 17, 'AEK Athens'),
  ('Obed Vargas', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 18, 'Atlético Madrid'),
  ('Gilberto Mora', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 19, 'Tijuana'),
  ('Mateo Chávez', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 20, 'AZ'),
  ('César Huerta', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 21, 'Anderlecht'),
  ('Guillermo Martínez', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 22, 'Pumas'),
  ('Jesús Gallardo', (SELECT id FROM public.teams WHERE code='MEX'), 'DF', 23, 'Toluca'),
  ('Luis Chávez', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 24, 'Dynamo Moscow'),
  ('Roberto Alvarado', (SELECT id FROM public.teams WHERE code='MEX'), 'FW', 25, 'Guadalajara'),
  ('Brian Gutiérrez', (SELECT id FROM public.teams WHERE code='MEX'), 'MF', 26, 'Guadalajara'),
  ('Ronwen Williams (captain)', (SELECT id FROM public.teams WHERE code='RSA'), 'GK', 1, 'Mamelodi Sundowns'),
  ('Thabang Matuludi', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 2, 'Polokwane City'),
  ('Khulumani Ndamane', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 3, 'Mamelodi Sundowns'),
  ('Teboho Mokoena', (SELECT id FROM public.teams WHERE code='RSA'), 'MF', 4, 'Mamelodi Sundowns'),
  ('Thalente Mbatha', (SELECT id FROM public.teams WHERE code='RSA'), 'MF', 5, 'Orlando Pirates'),
  ('Aubrey Modiba', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 6, 'Mamelodi Sundowns'),
  ('Oswin Appollis', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 7, 'Orlando Pirates'),
  ('Tshepang Moremi', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 8, 'Orlando Pirates'),
  ('Lyle Foster', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 9, 'Burnley'),
  ('Relebohile Mofokeng', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 10, 'Orlando Pirates'),
  ('Themba Zwane', (SELECT id FROM public.teams WHERE code='RSA'), 'MF', 11, 'Mamelodi Sundowns'),
  ('Thapelo Maseko', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 12, 'AEL Limassol'),
  ('Sphephelo Sithole', (SELECT id FROM public.teams WHERE code='RSA'), 'MF', 13, 'Tondela'),
  ('Mbekezeli Mbokazi', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 14, 'Chicago Fire FC'),
  ('Iqraam Rayners', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 15, 'Mamelodi Sundowns'),
  ('Sipho Chaine', (SELECT id FROM public.teams WHERE code='RSA'), 'GK', 16, 'Orlando Pirates'),
  ('Evidence Makgopa', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 17, 'Orlando Pirates'),
  ('Samukele Kabini', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 18, 'Molde'),
  ('Nkosinathi Sibisi', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 19, 'Orlando Pirates'),
  ('Khuliso Mudau', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 20, 'Mamelodi Sundowns'),
  ('Ime Okon', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 21, 'Hannover 96'),
  ('Ricardo Goss', (SELECT id FROM public.teams WHERE code='RSA'), 'GK', 22, 'Siwelele'),
  ('Jayden Adams', (SELECT id FROM public.teams WHERE code='RSA'), 'MF', 23, 'Mamelodi Sundowns'),
  ('Olwethu Makhanya', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 24, 'Philadelphia Union'),
  ('Kamogelo Sebelebele', (SELECT id FROM public.teams WHERE code='RSA'), 'FW', 25, 'Orlando Pirates'),
  ('Bradley Cross', (SELECT id FROM public.teams WHERE code='RSA'), 'DF', 26, 'Kaizer Chiefs'),
  ('Kim Seung-gyu', (SELECT id FROM public.teams WHERE code='KOR'), 'GK', 1, 'FC Tokyo'),
  ('Lee Han-beom', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 2, 'Midtjylland'),
  ('Lee Gi-hyuk', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 3, 'Gangwon FC'),
  ('Kim Min-jae', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 4, 'Bayern Munich'),
  ('Kim Tae-hyeon', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 5, 'Kashima Antlers'),
  ('Hwang In-beom', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 6, 'Feyenoord'),
  ('Son Heung-min (captain)', (SELECT id FROM public.teams WHERE code='KOR'), 'FW', 7, 'Los Angeles FC'),
  ('Paik Seung-ho', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 8, 'Birmingham City'),
  ('Cho Gue-sung', (SELECT id FROM public.teams WHERE code='KOR'), 'FW', 9, 'Midtjylland'),
  ('Lee Jae-sung', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 10, 'Mainz 05'),
  ('Hwang Hee-chan', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 11, 'Wolverhampton Wanderers'),
  ('Song Bum-keun', (SELECT id FROM public.teams WHERE code='KOR'), 'GK', 12, 'Jeonbuk Hyundai Motors'),
  ('Lee Tae-seok', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 13, 'Austria Wien'),
  ('Cho Wi-je', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 14, 'Jeonbuk Hyundai Motors'),
  ('Kim Moon-hwan', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 15, 'Daejeon Hana Citizen'),
  ('Park Jin-seob', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 16, 'Zhejiang'),
  ('Bae Jun-ho', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 17, 'Stoke City'),
  ('Oh Hyeon-gyu', (SELECT id FROM public.teams WHERE code='KOR'), 'FW', 18, 'Beşiktaş'),
  ('Lee Kang-in', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 19, 'Paris Saint-Germain'),
  ('Yang Hyun-jun', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 20, 'Celtic'),
  ('Jo Hyeon-woo', (SELECT id FROM public.teams WHERE code='KOR'), 'GK', 21, 'Ulsan HD'),
  ('Seol Young-woo', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 22, 'Red Star Belgrade'),
  ('Jens Castrop', (SELECT id FROM public.teams WHERE code='KOR'), 'DF', 23, 'Borussia Mönchengladbach'),
  ('Kim Jin-gyu', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 24, 'Jeonbuk Hyundai Motors'),
  ('Eom Ji-sung', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 25, 'Swansea City'),
  ('Lee Dong-gyeong', (SELECT id FROM public.teams WHERE code='KOR'), 'MF', 26, 'Ulsan HD'),
  ('Nikola Vasilj', (SELECT id FROM public.teams WHERE code='BIH'), 'GK', 1, 'FC St. Pauli'),
  ('Nihad Mujakić', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 2, 'Gaziantep'),
  ('Dennis Hadžikadunić', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 3, 'Sampdoria'),
  ('Tarik Muharemović', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 4, 'Sassuolo'),
  ('Sead Kolašinac', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 5, 'Atalanta'),
  ('Benjamin Tahirović', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 6, 'Brøndby'),
  ('Amar Dedić', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 7, 'Benfica'),
  ('Armin Gigović', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 8, 'Young Boys'),
  ('Samed Baždar', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 9, 'Jagiellonia Białystok'),
  ('Ermedin Demirović', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 10, 'VfB Stuttgart'),
  ('Edin Džeko (captain)', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 11, 'Schalke 04'),
  ('Mladen Jurkas', (SELECT id FROM public.teams WHERE code='BIH'), 'GK', 12, 'Borac Banja Luka'),
  ('Ivan Bašić', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 13, 'Astana'),
  ('Ivan Šunjić', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 14, 'Pafos'),
  ('Amar Memić', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 15, 'Viktoria Plzeň'),
  ('Amir Hadžiahmetović', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 16, 'Hull City'),
  ('Dženis Burnić', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 17, 'Karlsruher SC'),
  ('Nikola Katić', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 18, 'Schalke 04'),
  ('Kerim Alajbegović', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 19, 'Red Bull Salzburg'),
  ('Esmir Bajraktarević', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 20, 'PSV Eindhoven'),
  ('Stjepan Radeljić', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 21, 'Rijeka'),
  ('Martin Zlomislić', (SELECT id FROM public.teams WHERE code='BIH'), 'GK', 22, 'Rijeka'),
  ('Haris Tabaković', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 23, 'Borussia Mönchengladbach'),
  ('Nidal Čelik', (SELECT id FROM public.teams WHERE code='BIH'), 'DF', 24, 'Lens'),
  ('Jovo Lukić', (SELECT id FROM public.teams WHERE code='BIH'), 'FW', 25, 'Universitatea Cluj'),
  ('Ermin Mahmić', (SELECT id FROM public.teams WHERE code='BIH'), 'MF', 26, 'Slovan Liberec'),
  ('Dayne St. Clair', (SELECT id FROM public.teams WHERE code='CAN'), 'GK', 1, 'Inter Miami CF'),
  ('Alistair Johnston', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 2, 'Celtic'),
  ('Alfie Jones', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 3, 'Middlesbrough'),
  ('Luc de Fougerolles', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 4, 'Dender'),
  ('Joel Waterman', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 5, 'Chicago Fire FC'),
  ('Mathieu Choinière', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 6, 'Los Angeles FC'),
  ('Stephen Eustáquio', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 7, 'Los Angeles FC'),
  ('Ismaël Koné', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 8, 'Sassuolo'),
  ('Cyle Larin', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 9, 'Southampton'),
  ('Jonathan David', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 10, 'Juventus'),
  ('Liam Millar', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 11, 'Hull City'),
  ('Tani Oluwaseyi', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 12, 'Villarreal'),
  ('Derek Cornelius', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 13, 'Rangers'),
  ('Jacob Shaffelburg', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 14, 'Los Angeles FC'),
  ('Moïse Bombito', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 15, 'Nice'),
  ('Maxime Crépeau', (SELECT id FROM public.teams WHERE code='CAN'), 'GK', 16, 'Orlando City SC'),
  ('Tajon Buchanan', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 17, 'Villarreal'),
  ('Owen Goodman', (SELECT id FROM public.teams WHERE code='CAN'), 'GK', 18, 'Barnsley'),
  ('Alphonso Davies (captain)', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 19, 'Bayern Munich'),
  ('Ali Ahmed', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 20, 'Norwich City'),
  ('Jonathan Osorio', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 21, 'Toronto FC'),
  ('Richie Laryea', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 22, 'Toronto FC'),
  ('Niko Sigur', (SELECT id FROM public.teams WHERE code='CAN'), 'DF', 23, 'Hajduk Split'),
  ('Promise David', (SELECT id FROM public.teams WHERE code='CAN'), 'FW', 24, 'Union Saint-Gilloise'),
  ('Nathan Saliba', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 25, 'Anderlecht'),
  ('Jayden Nelson', (SELECT id FROM public.teams WHERE code='CAN'), 'MF', 26, 'Austin FC'),
  ('Mahmud Abunada', (SELECT id FROM public.teams WHERE code='QAT'), 'GK', 1, 'Al-Rayyan'),
  ('Pedro Miguel', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 2, 'Al-Sadd'),
  ('Lucas Mendes', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 3, 'Al-Wakrah'),
  ('Issa Laye', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 4, 'Al-Arabi'),
  ('Jassem Gaber', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 5, 'Al-Rayyan'),
  ('Abdulaziz Hatem', (SELECT id FROM public.teams WHERE code='QAT'), 'MF', 6, 'Al-Rayyan'),
  ('Ahmed Alaaeldin', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 7, 'Al-Rayyan'),
  ('Edmilson Junior', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 8, 'Al-Duhail'),
  ('Mohammed Muntari', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 9, 'Al-Gharafa'),
  ('Hassan Al-Haydos (captain)', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 10, 'Al-Sadd'),
  ('Akram Afif', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 11, 'Al-Sadd'),
  ('Karim Boudiaf', (SELECT id FROM public.teams WHERE code='QAT'), 'MF', 12, 'Al-Duhail'),
  ('Ayoub Al-Oui', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 13, 'Al-Gharafa'),
  ('Homam Ahmed', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 14, 'Cultural Leonesa'),
  ('Yusuf Abdurisag', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 15, 'Al-Wakrah'),
  ('Boualem Khoukhi', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 16, 'Al-Sadd'),
  ('Ahmed Al-Ganehi', (SELECT id FROM public.teams WHERE code='QAT'), 'MF', 17, 'Al-Gharafa'),
  ('Sultan Al-Brake', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 18, 'Al-Duhail'),
  ('Almoez Ali', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 19, 'Al-Duhail'),
  ('Ahmed Fathy', (SELECT id FROM public.teams WHERE code='QAT'), 'MF', 20, 'Al-Arabi'),
  ('Salah Zakaria', (SELECT id FROM public.teams WHERE code='QAT'), 'GK', 21, 'Al-Duhail'),
  ('Meshaal Barsham', (SELECT id FROM public.teams WHERE code='QAT'), 'GK', 22, 'Al-Sadd'),
  ('Assim Madibo', (SELECT id FROM public.teams WHERE code='QAT'), 'MF', 23, 'Al-Wakrah'),
  ('Tahsin Jamshid', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 24, 'Al-Duhail'),
  ('Al-Hashmi Al-Hussain', (SELECT id FROM public.teams WHERE code='QAT'), 'DF', 25, 'Al-Arabi'),
  ('Mohamed Manai', (SELECT id FROM public.teams WHERE code='QAT'), 'FW', 26, 'Al-Shamal'),
  ('Gregor Kobel', (SELECT id FROM public.teams WHERE code='SUI'), 'GK', 1, 'Borussia Dortmund'),
  ('Miro Muheim', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 2, 'Hamburger SV'),
  ('Silvan Widmer', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 3, 'Mainz 05'),
  ('Nico Elvedi', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 4, 'Borussia Mönchengladbach'),
  ('Manuel Akanji', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 5, 'Inter Milan'),
  ('Denis Zakaria', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 6, 'Monaco'),
  ('Breel Embolo', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 7, 'Rennes'),
  ('Remo Freuler', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 8, 'Bologna'),
  ('Johan Manzambi', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 9, 'SC Freiburg'),
  ('Granit Xhaka (captain)', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 10, 'Sunderland'),
  ('Dan Ndoye', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 11, 'Nottingham Forest'),
  ('Yvon Mvogo', (SELECT id FROM public.teams WHERE code='SUI'), 'GK', 12, 'Lorient'),
  ('Ricardo Rodriguez', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 13, 'Real Betis'),
  ('Ardon Jashari', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 14, 'Milan'),
  ('Djibril Sow', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 15, 'Sevilla'),
  ('Christian Fassnacht', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 16, 'Young Boys'),
  ('Rubén Vargas', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 17, 'Sevilla'),
  ('Eray Cömert', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 18, 'Valencia'),
  ('Noah Okafor', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 19, 'Leeds United'),
  ('Michel Aebischer', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 20, 'Pisa'),
  ('Marvin Keller', (SELECT id FROM public.teams WHERE code='SUI'), 'GK', 21, 'Young Boys'),
  ('Fabian Rieder', (SELECT id FROM public.teams WHERE code='SUI'), 'MF', 22, 'FC Augsburg'),
  ('Zeki Amdouni', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 23, 'Burnley'),
  ('Aurèle Amenda', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 24, 'Eintracht Frankfurt'),
  ('Luca Jaquez', (SELECT id FROM public.teams WHERE code='SUI'), 'DF', 25, 'VfB Stuttgart'),
  ('Cedric Itten', (SELECT id FROM public.teams WHERE code='SUI'), 'FW', 26, 'Fortuna Düsseldorf'),
  ('Alisson', (SELECT id FROM public.teams WHERE code='BRA'), 'GK', 1, 'Liverpool'),
  ('Éderson Silva', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 2, 'Atalanta'),
  ('Gabriel Magalhães', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 3, 'Arsenal'),
  ('Marquinhos (captain)', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 4, 'Paris Saint-Germain'),
  ('Casemiro', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 5, 'Manchester United'),
  ('Alex Sandro', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 6, 'Flamengo'),
  ('Vinícius Júnior', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 7, 'Real Madrid'),
  ('Bruno Guimarães', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 8, 'Newcastle United'),
  ('Matheus Cunha', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 9, 'Manchester United'),
  ('Neymar', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 10, 'Santos'),
  ('Raphinha', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 11, 'Barcelona'),
  ('Weverton', (SELECT id FROM public.teams WHERE code='BRA'), 'GK', 12, 'Grêmio'),
  ('Danilo Luiz', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 13, 'Flamengo'),
  ('Bremer', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 14, 'Juventus'),
  ('Léo Pereira', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 15, 'Flamengo'),
  ('Douglas Santos', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 16, 'Zenit Saint Petersburg'),
  ('Fabinho', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 17, 'Al-Ittihad'),
  ('Danilo Santos', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 18, 'Botafogo'),
  ('Endrick', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 19, 'Lyon'),
  ('Lucas Paquetá', (SELECT id FROM public.teams WHERE code='BRA'), 'MF', 20, 'Flamengo'),
  ('Luiz Henrique', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 21, 'Zenit Saint Petersburg'),
  ('Gabriel Martinelli', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 22, 'Arsenal'),
  ('Ederson Moraes', (SELECT id FROM public.teams WHERE code='BRA'), 'GK', 23, 'Fenerbahçe'),
  ('Roger Ibañez', (SELECT id FROM public.teams WHERE code='BRA'), 'DF', 24, 'Al-Ahli'),
  ('Igor Thiago', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 25, 'Brentford'),
  ('Rayan', (SELECT id FROM public.teams WHERE code='BRA'), 'FW', 26, 'Bournemouth'),
  ('Johny Placide (captain)', (SELECT id FROM public.teams WHERE code='HAI'), 'GK', 1, 'Bastia'),
  ('Carlens Arcus', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 2, 'Angers'),
  ('Keeto Thermoncy', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 3, 'Young Boys'),
  ('Ricardo Adé', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 4, 'LDU Quito'),
  ('Hannes Delcroix', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 5, 'Lugano'),
  ('Carl Sainté', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 6, 'El Paso Locomotive FC'),
  ('Derrick Etienne Jr.', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 7, 'Toronto FC'),
  ('Martin Expérience', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 8, 'Nancy'),
  ('Duckens Nazon', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 9, 'Esteghlal'),
  ('Jean-Ricner Bellegarde', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 10, 'Wolverhampton Wanderers'),
  ('Louicius Deedson', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 11, 'FC Dallas'),
  ('Alexandre Pierre', (SELECT id FROM public.teams WHERE code='HAI'), 'GK', 12, 'Sochaux'),
  ('Duke Lacroix', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 13, 'Colorado Springs Switchbacks FC'),
  ('Leverton Pierre', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 14, 'Vizela'),
  ('Ruben Providence', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 15, 'Almere City'),
  ('Lenny Joseph', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 16, 'Ferencváros'),
  ('Danley Jean Jacques', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 17, 'Philadelphia Union'),
  ('Wilson Isidor', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 18, 'Sunderland'),
  ('Yassin Fortuné', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 19, 'Vizela'),
  ('Frantzdy Pierrot', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 20, 'Çaykur Rizespor'),
  ('Josué Casimir', (SELECT id FROM public.teams WHERE code='HAI'), 'FW', 21, 'Auxerre'),
  ('Jean-Kévin Duverne', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 22, 'Gent'),
  ('Josué Duverger', (SELECT id FROM public.teams WHERE code='HAI'), 'GK', 23, 'Cosmos Koblenz'),
  ('Wilguens Paugain', (SELECT id FROM public.teams WHERE code='HAI'), 'DF', 24, 'Zulte Waregem'),
  ('Dominique Simon', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 25, 'Tatran Prešov'),
  ('Woodensky Pierre', (SELECT id FROM public.teams WHERE code='HAI'), 'MF', 26, 'Violette'),
  ('Yassine Bounou', (SELECT id FROM public.teams WHERE code='MAR'), 'GK', 1, 'Al-Hilal'),
  ('Achraf Hakimi (captain)', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 2, 'Paris Saint-Germain'),
  ('Noussair Mazraoui', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 3, 'Manchester United'),
  ('Sofyan Amrabat', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 4, 'Real Betis'),
  ('Nayef Aguerd', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 5, 'Marseille'),
  ('Ayyoub Bouaddi', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 6, 'Lille'),
  ('Chemsdine Talbi', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 7, 'Sunderland'),
  ('Azzedine Ounahi', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 8, 'Girona'),
  ('Soufiane Rahimi', (SELECT id FROM public.teams WHERE code='MAR'), 'FW', 9, 'Al Ain'),
  ('Brahim Díaz', (SELECT id FROM public.teams WHERE code='MAR'), 'FW', 10, 'Real Madrid'),
  ('Ismael Saibari', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 11, 'PSV Eindhoven'),
  ('Munir Mohamedi', (SELECT id FROM public.teams WHERE code='MAR'), 'GK', 12, 'RS Berkane'),
  ('Zakaria El Ouahdi', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 13, 'Genk'),
  ('Issa Diop', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 14, 'Fulham'),
  ('Samir El Mourabet', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 15, 'Strasbourg'),
  ('Gessime Yassine', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 16, 'Strasbourg'),
  ('Abde Ezzalzouli', (SELECT id FROM public.teams WHERE code='MAR'), 'FW', 17, 'Real Betis'),
  ('Chadi Riad', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 18, 'Crystal Palace'),
  ('Youssef Belammari', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 19, 'Al Ahly'),
  ('Ayoub El Kaabi', (SELECT id FROM public.teams WHERE code='MAR'), 'FW', 20, 'Olympiacos'),
  ('Ayoube Amaimouni', (SELECT id FROM public.teams WHERE code='MAR'), 'FW', 21, 'Eintracht Frankfurt'),
  ('Ahmed Reda Tagnaouti', (SELECT id FROM public.teams WHERE code='MAR'), 'GK', 22, 'AS FAR'),
  ('Bilal El Khannouss', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 23, 'VfB Stuttgart'),
  ('Neil El Aynaoui', (SELECT id FROM public.teams WHERE code='MAR'), 'MF', 24, 'Roma'),
  ('Redouane Halhal', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 25, 'Mechelen'),
  ('Anass Salah-Eddine', (SELECT id FROM public.teams WHERE code='MAR'), 'DF', 26, 'PSV Eindhoven'),
  ('Angus Gunn', (SELECT id FROM public.teams WHERE code='SCO'), 'GK', 1, 'Nottingham Forest'),
  ('Aaron Hickey', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 2, 'Brentford'),
  ('Andy Robertson (captain)', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 3, 'Liverpool'),
  ('Scott McTominay', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 4, 'Napoli'),
  ('Grant Hanley', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 5, 'Hibernian'),
  ('Kieran Tierney', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 6, 'Celtic'),
  ('John McGinn', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 7, 'Aston Villa'),
  ('Tyler Fletcher', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 8, 'Manchester United'),
  ('Lyndon Dykes', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 9, 'Charlton Athletic'),
  ('Ché Adams', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 10, 'Torino'),
  ('Ryan Christie', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 11, 'Bournemouth'),
  ('Liam Kelly', (SELECT id FROM public.teams WHERE code='SCO'), 'GK', 12, 'Rangers'),
  ('Jack Hendry', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 13, 'Al-Ettifaq'),
  ('Ross Stewart', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 14, 'Southampton'),
  ('John Souttar', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 15, 'Rangers'),
  ('Dominic Hyam', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 16, 'Wrexham'),
  ('Ben Gannon-Doak', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 17, 'Bournemouth'),
  ('George Hirst', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 18, 'Ipswich Town'),
  ('Lewis Ferguson', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 19, 'Bologna'),
  ('Lawrence Shankland', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 20, 'Heart of Midlothian'),
  ('Craig Gordon', (SELECT id FROM public.teams WHERE code='SCO'), 'GK', 21, 'Heart of Midlothian'),
  ('Nathan Patterson', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 22, 'Everton'),
  ('Kenny McLean', (SELECT id FROM public.teams WHERE code='SCO'), 'MF', 23, 'Norwich City'),
  ('Anthony Ralston', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 24, 'Celtic'),
  ('Findlay Curtis', (SELECT id FROM public.teams WHERE code='SCO'), 'FW', 25, 'Kilmarnock'),
  ('Scott McKenna', (SELECT id FROM public.teams WHERE code='SCO'), 'DF', 26, 'Dinamo Zagreb'),
  ('Mathew Ryan (captain)', (SELECT id FROM public.teams WHERE code='AUS'), 'GK', 1, 'Levante'),
  ('Miloš Degenek', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 2, 'APOEL'),
  ('Alessandro Circati', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 3, 'Parma'),
  ('Jacob Italiano', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 4, 'Grazer AK'),
  ('Jordan Bos', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 5, 'Feyenoord'),
  ('Jason Geria', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 6, 'Albirex Niigata'),
  ('Mathew Leckie', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 7, 'Melbourne City'),
  ('Connor Metcalfe', (SELECT id FROM public.teams WHERE code='AUS'), 'MF', 8, 'FC St. Pauli'),
  ('Mohamed Touré', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 9, 'Norwich City'),
  ('Ajdin Hrustic', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 10, 'Heracles Almelo'),
  ('Awer Mabil', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 11, 'Castellón'),
  ('Paul Izzo', (SELECT id FROM public.teams WHERE code='AUS'), 'GK', 12, 'Randers'),
  ('Aiden O''Neill', (SELECT id FROM public.teams WHERE code='AUS'), 'MF', 13, 'New York City FC'),
  ('Cammy Devlin', (SELECT id FROM public.teams WHERE code='AUS'), 'MF', 14, 'Heart of Midlothian'),
  ('Kai Trewin', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 15, 'New York City FC'),
  ('Aziz Behich', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 16, 'Melbourne City'),
  ('Nestory Irankunda', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 17, 'Watford'),
  ('Patrick Beach', (SELECT id FROM public.teams WHERE code='AUS'), 'GK', 18, 'Melbourne City'),
  ('Harry Souttar', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 19, 'Leicester City'),
  ('Cristian Volpato', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 20, 'Sassuolo'),
  ('Cameron Burgess', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 21, 'Swansea City'),
  ('Jackson Irvine', (SELECT id FROM public.teams WHERE code='AUS'), 'MF', 22, 'FC St. Pauli'),
  ('Nishan Velupillay', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 23, 'Melbourne Victory'),
  ('Paul Okon-Engstler', (SELECT id FROM public.teams WHERE code='AUS'), 'MF', 24, 'Sydney FC'),
  ('Lucas Herrington', (SELECT id FROM public.teams WHERE code='AUS'), 'DF', 25, 'Colorado Rapids'),
  ('Tete Yengi', (SELECT id FROM public.teams WHERE code='AUS'), 'FW', 26, 'Machida Zelvia'),
  ('Gatito Fernández', (SELECT id FROM public.teams WHERE code='PAR'), 'GK', 1, 'Cerro Porteño'),
  ('Gustavo Velázquez', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 2, 'Cerro Porteño'),
  ('Omar Alderete', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 3, 'Sunderland'),
  ('Juan José Cáceres', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 4, 'Dynamo Moscow'),
  ('Fabián Balbuena', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 5, 'Grêmio'),
  ('Júnior Alonso', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 6, 'Atlético Mineiro'),
  ('Ramón Sosa', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 7, 'Palmeiras'),
  ('Diego Gómez', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 8, 'Brighton & Hove Albion'),
  ('Antonio Sanabria', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 9, 'Cremonese'),
  ('Miguel Almirón', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 10, 'Atlanta United FC'),
  ('Maurício', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 11, 'Palmeiras'),
  ('Orlando Gill', (SELECT id FROM public.teams WHERE code='PAR'), 'GK', 12, 'San Lorenzo'),
  ('José Canale', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 13, 'Lanús'),
  ('Andrés Cubas', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 14, 'Vancouver Whitecaps FC'),
  ('Gustavo Gómez (captain)', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 15, 'Palmeiras'),
  ('Damián Bobadilla', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 16, 'São Paulo'),
  ('Kaku', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 17, 'Al Ain'),
  ('Álex Arce', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 18, 'Independiente Rivadavia'),
  ('Julio Enciso', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 19, 'Strasbourg'),
  ('Braian Ojeda', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 20, 'Orlando City SC'),
  ('Gabriel Ávalos', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 21, 'Independiente'),
  ('Gastón Olveira', (SELECT id FROM public.teams WHERE code='PAR'), 'GK', 22, 'Olimpia'),
  ('Matías Galarza', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 23, 'Atlanta United FC'),
  ('Gustavo Caballero', (SELECT id FROM public.teams WHERE code='PAR'), 'MF', 24, 'Portsmouth'),
  ('Isidro Pitta', (SELECT id FROM public.teams WHERE code='PAR'), 'FW', 25, 'Red Bull Bragantino'),
  ('Alexandro Maidana', (SELECT id FROM public.teams WHERE code='PAR'), 'DF', 26, 'Talleres'),
  ('Mert Günok', (SELECT id FROM public.teams WHERE code='TUR'), 'GK', 1, 'Fenerbahçe'),
  ('Zeki Çelik', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 2, 'Roma'),
  ('Merih Demiral', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 3, 'Al-Ahli'),
  ('Çağlar Söyüncü', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 4, 'Fenerbahçe'),
  ('Salih Özcan', (SELECT id FROM public.teams WHERE code='TUR'), 'MF', 5, 'Borussia Dortmund'),
  ('Orkun Kökçü', (SELECT id FROM public.teams WHERE code='TUR'), 'MF', 6, 'Beşiktaş'),
  ('Kerem Aktürkoğlu', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 7, 'Fenerbahçe'),
  ('Arda Güler', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 8, 'Real Madrid'),
  ('Deniz Gül', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 9, 'Porto'),
  ('Hakan Çalhanoğlu (captain)', (SELECT id FROM public.teams WHERE code='TUR'), 'MF', 10, 'Inter Milan'),
  ('Kenan Yıldız', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 11, 'Juventus'),
  ('Altay Bayındır', (SELECT id FROM public.teams WHERE code='TUR'), 'GK', 12, 'Manchester United'),
  ('Eren Elmalı', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 13, 'Galatasaray'),
  ('Abdülkerim Bardakcı', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 14, 'Galatasaray'),
  ('Ozan Kabak', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 15, 'TSG Hoffenheim'),
  ('İsmail Yüksek', (SELECT id FROM public.teams WHERE code='TUR'), 'MF', 16, 'Fenerbahçe'),
  ('İrfan Can Kahveci', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 17, 'Kasımpaşa'),
  ('Mert Müldür', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 18, 'Fenerbahçe'),
  ('Yunus Akgün', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 19, 'Galatasaray'),
  ('Ferdi Kadıoğlu', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 20, 'Brighton & Hove Albion'),
  ('Barış Alper Yılmaz', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 21, 'Galatasaray'),
  ('Kaan Ayhan', (SELECT id FROM public.teams WHERE code='TUR'), 'MF', 22, 'Galatasaray'),
  ('Uğurcan Çakır', (SELECT id FROM public.teams WHERE code='TUR'), 'GK', 23, 'Galatasaray'),
  ('Oğuz Aydın', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 24, 'Fenerbahçe'),
  ('Samet Akaydin', (SELECT id FROM public.teams WHERE code='TUR'), 'DF', 25, 'Çaykur Rizespor'),
  ('Can Uzun', (SELECT id FROM public.teams WHERE code='TUR'), 'FW', 26, 'Eintracht Frankfurt'),
  ('Matt Turner', (SELECT id FROM public.teams WHERE code='USA'), 'GK', 1, 'New England Revolution'),
  ('Sergiño Dest', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 2, 'PSV Eindhoven'),
  ('Chris Richards', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 3, 'Crystal Palace'),
  ('Tyler Adams', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 4, 'Bournemouth'),
  ('Antonee Robinson', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 5, 'Fulham'),
  ('Auston Trusty', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 6, 'Celtic'),
  ('Giovanni Reyna', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 7, 'Borussia Mönchengladbach'),
  ('Weston McKennie', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 8, 'Juventus'),
  ('Ricardo Pepi', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 9, 'PSV Eindhoven'),
  ('Christian Pulisic', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 10, 'Milan'),
  ('Brenden Aaronson', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 11, 'Leeds United'),
  ('Miles Robinson', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 12, 'FC Cincinnati'),
  ('Tim Ream (captain)', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 13, 'Charlotte FC'),
  ('Sebastian Berhalter', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 14, 'Vancouver Whitecaps FC'),
  ('Cristian Roldan', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 15, 'Seattle Sounders FC'),
  ('Alex Freeman', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 16, 'Villarreal'),
  ('Malik Tillman', (SELECT id FROM public.teams WHERE code='USA'), 'MF', 17, 'Bayer Leverkusen'),
  ('Max Arfsten', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 18, 'Columbus Crew'),
  ('Haji Wright', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 19, 'Coventry City'),
  ('Folarin Balogun', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 20, 'Monaco'),
  ('Timothy Weah', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 21, 'Marseille'),
  ('Mark McKenzie', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 22, 'Toulouse'),
  ('Joe Scally', (SELECT id FROM public.teams WHERE code='USA'), 'DF', 23, 'Borussia Mönchengladbach'),
  ('Matt Freese', (SELECT id FROM public.teams WHERE code='USA'), 'GK', 24, 'New York City FC'),
  ('Chris Brady', (SELECT id FROM public.teams WHERE code='USA'), 'GK', 25, 'Chicago Fire FC'),
  ('Alejandro Zendejas', (SELECT id FROM public.teams WHERE code='USA'), 'FW', 26, 'América'),
  ('Eloy Room', (SELECT id FROM public.teams WHERE code='CUW'), 'GK', 1, 'Miami FC'),
  ('Shurandy Sambo', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 2, 'Sparta Rotterdam'),
  ('Juriën Gaari', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 3, 'Abha'),
  ('Roshon van Eijma', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 4, 'RKC Waalwijk'),
  ('Sherel Floranus', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 5, 'PEC Zwolle'),
  ('Godfried Roemeratoe', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 6, 'RKC Waalwijk'),
  ('Juninho Bacuna', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 7, 'Volendam'),
  ('Livano Comenencia', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 8, 'Zürich'),
  ('Jürgen Locadia', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 9, 'Miami FC'),
  ('Leandro Bacuna (captain)', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 10, 'Iğdır'),
  ('Jeremy Antonisse', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 11, 'Kifisia'),
  ('Sontje Hansen', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 12, 'Middlesbrough'),
  ('Tyrese Noslin', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 13, 'Telstar'),
  ('Kenji Gorré', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 14, 'Maccabi Haifa'),
  ('Ar''jany Martha', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 15, 'Rotherham United'),
  ('Jearl Margaritha', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 16, 'Beveren'),
  ('Brandley Kuwas', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 17, 'Volendam'),
  ('Armando Obispo', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 18, 'PSV Eindhoven'),
  ('Gervane Kastaneer', (SELECT id FROM public.teams WHERE code='CUW'), 'FW', 19, 'Terengganu'),
  ('Joshua Brenet', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 20, 'Kayserispor'),
  ('Tahith Chong', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 21, 'Sheffield United'),
  ('Kevin Felida', (SELECT id FROM public.teams WHERE code='CUW'), 'MF', 22, 'Den Bosch'),
  ('Riechedly Bazoer', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 23, 'Konyaspor'),
  ('Deveron Fonville', (SELECT id FROM public.teams WHERE code='CUW'), 'DF', 24, 'NEC'),
  ('Tyrick Bodak', (SELECT id FROM public.teams WHERE code='CUW'), 'GK', 25, 'Telstar'),
  ('Trevor Doornbusch', (SELECT id FROM public.teams WHERE code='CUW'), 'GK', 26, 'VVV-Venlo'),
  ('Hernán Galíndez', (SELECT id FROM public.teams WHERE code='ECU'), 'GK', 1, 'Huracán'),
  ('Félix Torres', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 2, 'Internacional'),
  ('Piero Hincapié', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 3, 'Arsenal'),
  ('Joel Ordóñez', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 4, 'Club Brugge'),
  ('Jordy Alcívar', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 5, 'Independiente del Valle'),
  ('Willian Pacho', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 6, 'Paris Saint-Germain'),
  ('Pervis Estupiñán', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 7, 'Milan'),
  ('Anthony Valencia', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 8, 'Antwerp'),
  ('John Yeboah', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 9, 'Venezia'),
  ('Kendry Páez', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 10, 'River Plate'),
  ('Kevin Rodríguez', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 11, 'Union Saint-Gilloise'),
  ('Moisés Ramírez', (SELECT id FROM public.teams WHERE code='ECU'), 'GK', 12, 'Kifisia'),
  ('Enner Valencia (captain)', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 13, 'Pachuca'),
  ('Alan Minda', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 14, 'Atlético Mineiro'),
  ('Pedro Vite', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 15, 'UNAM'),
  ('Jordy Caicedo', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 16, 'Huracán'),
  ('Ángelo Preciado', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 17, 'Atlético Mineiro'),
  ('Denil Castillo', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 18, 'Midtjylland'),
  ('Gonzalo Plata', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 19, 'Flamengo'),
  ('Nilson Angulo', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 20, 'Sunderland'),
  ('Alan Franco', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 21, 'Atlético Mineiro'),
  ('Gonzalo Valle', (SELECT id FROM public.teams WHERE code='ECU'), 'GK', 22, 'LDU Quito'),
  ('Moisés Caicedo', (SELECT id FROM public.teams WHERE code='ECU'), 'MF', 23, 'Chelsea'),
  ('Jeremy Arévalo', (SELECT id FROM public.teams WHERE code='ECU'), 'FW', 24, 'VfB Stuttgart'),
  ('Jackson Porozo', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 25, 'Tijuana'),
  ('Yaimar Medina', (SELECT id FROM public.teams WHERE code='ECU'), 'DF', 26, 'Genk'),
  ('Manuel Neuer', (SELECT id FROM public.teams WHERE code='GER'), 'GK', 1, 'Bayern Munich'),
  ('Antonio Rüdiger', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 2, 'Real Madrid'),
  ('Waldemar Anton', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 3, 'Borussia Dortmund'),
  ('Jonathan Tah', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 4, 'Bayern Munich'),
  ('Aleksandar Pavlović', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 5, 'Bayern Munich'),
  ('Joshua Kimmich (captain)', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 6, 'Bayern Munich'),
  ('Kai Havertz', (SELECT id FROM public.teams WHERE code='GER'), 'FW', 7, 'Arsenal'),
  ('Leon Goretzka', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 8, 'Bayern Munich'),
  ('Jamie Leweling', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 9, 'VfB Stuttgart'),
  ('Jamal Musiala', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 10, 'Bayern Munich'),
  ('Nick Woltemade', (SELECT id FROM public.teams WHERE code='GER'), 'FW', 11, 'Newcastle United'),
  ('Oliver Baumann', (SELECT id FROM public.teams WHERE code='GER'), 'GK', 12, 'TSG Hoffenheim'),
  ('Pascal Groß', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 13, 'Brighton & Hove Albion'),
  ('Maximilian Beier', (SELECT id FROM public.teams WHERE code='GER'), 'FW', 14, 'Borussia Dortmund'),
  ('Nico Schlotterbeck', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 15, 'Borussia Dortmund'),
  ('Angelo Stiller', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 16, 'VfB Stuttgart'),
  ('Florian Wirtz', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 17, 'Liverpool'),
  ('Nathaniel Brown', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 18, 'Eintracht Frankfurt'),
  ('Leroy Sané', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 19, 'Galatasaray'),
  ('Nadiem Amiri', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 20, 'Mainz 05'),
  ('Alexander Nübel', (SELECT id FROM public.teams WHERE code='GER'), 'GK', 21, 'VfB Stuttgart'),
  ('David Raum', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 22, 'RB Leipzig'),
  ('Felix Nmecha', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 23, 'Borussia Dortmund'),
  ('Malick Thiaw', (SELECT id FROM public.teams WHERE code='GER'), 'DF', 24, 'Newcastle United'),
  ('Assan Ouédraogo', (SELECT id FROM public.teams WHERE code='GER'), 'MF', 25, 'RB Leipzig'),
  ('Deniz Undav', (SELECT id FROM public.teams WHERE code='GER'), 'FW', 26, 'VfB Stuttgart'),
  ('Yahia Fofana', (SELECT id FROM public.teams WHERE code='CIV'), 'GK', 1, 'Çaykur Rizespor'),
  ('Ousmane Diomande', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 2, 'Sporting CP'),
  ('Ghislain Konan', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 3, 'Gil Vicente'),
  ('Jean Michaël Seri', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 4, 'Maribor'),
  ('Wilfried Singo', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 5, 'Galatasaray'),
  ('Seko Fofana', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 6, 'Porto'),
  ('Odilon Kossounou', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 7, 'Atalanta'),
  ('Franck Kessié (captain)', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 8, 'Al-Ahli'),
  ('Ange-Yoan Bonny', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 9, 'Inter Milan'),
  ('Simon Adingra', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 10, 'Monaco'),
  ('Yan Diomande', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 11, 'RB Leipzig'),
  ('Elye Wahi', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 12, 'Nice'),
  ('Christopher Opéri', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 13, 'İstanbul Başakşehir'),
  ('Oumar Diakité', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 14, 'Cercle Brugge'),
  ('Amad Diallo', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 15, 'Manchester United'),
  ('Mohamed Koné', (SELECT id FROM public.teams WHERE code='CIV'), 'GK', 16, 'Charleroi'),
  ('Guéla Doué', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 17, 'Strasbourg'),
  ('Ibrahim Sangaré', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 18, 'Nottingham Forest'),
  ('Nicolas Pépé', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 19, 'Villarreal'),
  ('Emmanuel Agbadou', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 20, 'Beşiktaş'),
  ('Evan Ndicka', (SELECT id FROM public.teams WHERE code='CIV'), 'DF', 21, 'Roma'),
  ('Evann Guessand', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 22, 'Crystal Palace'),
  ('Alban Lafont', (SELECT id FROM public.teams WHERE code='CIV'), 'GK', 23, 'Panathinaikos'),
  ('Bazoumana Touré', (SELECT id FROM public.teams WHERE code='CIV'), 'FW', 24, 'TSG Hoffenheim'),
  ('Parfait Guiagon', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 25, 'Charleroi'),
  ('Christ Inao Oulaï', (SELECT id FROM public.teams WHERE code='CIV'), 'MF', 26, 'Trabzonspor'),
  ('Zion Suzuki', (SELECT id FROM public.teams WHERE code='JPN'), 'GK', 1, 'Parma'),
  ('Yukinari Sugawara', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 2, 'Werder Bremen'),
  ('Shōgo Taniguchi', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 3, 'Sint-Truiden'),
  ('Kō Itakura', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 4, 'Ajax'),
  ('Yūto Nagatomo', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 5, 'FC Tokyo'),
  ('Wataru Endo (captain)', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 6, 'Liverpool'),
  ('Ao Tanaka', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 7, 'Leeds United'),
  ('Takefusa Kubo', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 8, 'Real Sociedad'),
  ('Keisuke Gotō', (SELECT id FROM public.teams WHERE code='JPN'), 'FW', 9, 'Sint-Truiden'),
  ('Ritsu Dōan', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 10, 'Eintracht Frankfurt'),
  ('Daizen Maeda', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 11, 'Celtic'),
  ('Keisuke Ōsako', (SELECT id FROM public.teams WHERE code='JPN'), 'GK', 12, 'Sanfrecce Hiroshima'),
  ('Keito Nakamura', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 13, 'Reims'),
  ('Junya Itō', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 14, 'Genk'),
  ('Daichi Kamada', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 15, 'Crystal Palace'),
  ('Tsuyoshi Watanabe', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 16, 'Feyenoord'),
  ('Yuito Suzuki', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 17, 'SC Freiburg'),
  ('Ayase Ueda', (SELECT id FROM public.teams WHERE code='JPN'), 'FW', 18, 'Feyenoord'),
  ('Kōki Ogawa', (SELECT id FROM public.teams WHERE code='JPN'), 'FW', 19, 'NEC'),
  ('Ayumu Seko', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 20, 'Le Havre'),
  ('Hiroki Itō', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 21, 'Bayern Munich'),
  ('Takehiro Tomiyasu', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 22, 'Ajax'),
  ('Tomoki Hayakawa', (SELECT id FROM public.teams WHERE code='JPN'), 'GK', 23, 'Kashima Antlers'),
  ('Kaishū Sano', (SELECT id FROM public.teams WHERE code='JPN'), 'MF', 24, 'Mainz 05'),
  ('Junnosuke Suzuki', (SELECT id FROM public.teams WHERE code='JPN'), 'DF', 25, 'Copenhagen'),
  ('Kento Shiogai', (SELECT id FROM public.teams WHERE code='JPN'), 'FW', 26, 'VfL Wolfsburg'),
  ('Bart Verbruggen', (SELECT id FROM public.teams WHERE code='NED'), 'GK', 1, 'Brighton & Hove Albion'),
  ('Lutsharel Geertruida', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 2, 'Sunderland'),
  ('Marten de Roon', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 3, 'Atalanta'),
  ('Virgil van Dijk (captain)', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 4, 'Liverpool'),
  ('Nathan Aké', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 5, 'Manchester City'),
  ('Jan Paul van Hecke', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 6, 'Brighton & Hove Albion'),
  ('Justin Kluivert', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 7, 'Bournemouth'),
  ('Ryan Gravenberch', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 8, 'Liverpool'),
  ('Wout Weghorst', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 9, 'Ajax'),
  ('Memphis Depay', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 10, 'Corinthians'),
  ('Cody Gakpo', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 11, 'Liverpool'),
  ('Mats Wieffer', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 12, 'Brighton & Hove Albion'),
  ('Robin Roefs', (SELECT id FROM public.teams WHERE code='NED'), 'GK', 13, 'Sunderland'),
  ('Tijjani Reijnders', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 14, 'Manchester City'),
  ('Micky van de Ven', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 15, 'Tottenham Hotspur'),
  ('Guus Til', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 16, 'PSV Eindhoven'),
  ('Noa Lang', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 17, 'Galatasaray'),
  ('Donyell Malen', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 18, 'Roma'),
  ('Brian Brobbey', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 19, 'Sunderland'),
  ('Teun Koopmeiners', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 20, 'Juventus'),
  ('Frenkie de Jong', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 21, 'Barcelona'),
  ('Denzel Dumfries', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 22, 'Inter Milan'),
  ('Mark Flekken', (SELECT id FROM public.teams WHERE code='NED'), 'GK', 23, 'Bayer Leverkusen'),
  ('Crysencio Summerville', (SELECT id FROM public.teams WHERE code='NED'), 'FW', 24, 'West Ham United'),
  ('Jorrel Hato', (SELECT id FROM public.teams WHERE code='NED'), 'DF', 25, 'Chelsea'),
  ('Quinten Timber', (SELECT id FROM public.teams WHERE code='NED'), 'MF', 26, 'Marseille'),
  ('Jacob Widell Zetterström', (SELECT id FROM public.teams WHERE code='SWE'), 'GK', 1, 'Derby County'),
  ('Gustaf Lagerbielke', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 2, 'Braga'),
  ('Victor Lindelöf (captain)', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 3, 'Aston Villa'),
  ('Isak Hien', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 4, 'Atalanta'),
  ('Gabriel Gudmundsson', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 5, 'Leeds United'),
  ('Herman Johansson', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 6, 'FC Dallas'),
  ('Lucas Bergvall', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 7, 'Tottenham Hotspur'),
  ('Daniel Svensson', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 8, 'Borussia Dortmund'),
  ('Alexander Isak', (SELECT id FROM public.teams WHERE code='SWE'), 'FW', 9, 'Liverpool'),
  ('Benjamin Nygren', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 10, 'Celtic'),
  ('Anthony Elanga', (SELECT id FROM public.teams WHERE code='SWE'), 'FW', 11, 'Newcastle United'),
  ('Viktor Johansson', (SELECT id FROM public.teams WHERE code='SWE'), 'GK', 12, 'Stoke City'),
  ('Ken Sema', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 13, 'Pafos'),
  ('Hjalmar Ekdal', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 14, 'Burnley'),
  ('Carl Starfelt', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 15, 'Celta Vigo'),
  ('Jesper Karlström', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 16, 'Udinese'),
  ('Viktor Gyökeres', (SELECT id FROM public.teams WHERE code='SWE'), 'FW', 17, 'Arsenal'),
  ('Yasin Ayari', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 18, 'Brighton & Hove Albion'),
  ('Mattias Svanberg', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 19, 'VfL Wolfsburg'),
  ('Eric Smith', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 20, 'FC St. Pauli'),
  ('Alexander Bernhardsson', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 21, 'Holstein Kiel'),
  ('Besfort Zeneli', (SELECT id FROM public.teams WHERE code='SWE'), 'MF', 22, 'Union Saint-Gilloise'),
  ('Kristoffer Nordfeldt', (SELECT id FROM public.teams WHERE code='SWE'), 'GK', 23, 'AIK'),
  ('Elliot Stroud', (SELECT id FROM public.teams WHERE code='SWE'), 'DF', 24, 'Mjällby AIF'),
  ('Gustaf Nilsson', (SELECT id FROM public.teams WHERE code='SWE'), 'FW', 25, 'Club Brugge'),
  ('Taha Ali', (SELECT id FROM public.teams WHERE code='SWE'), 'FW', 26, 'Malmö FF'),
  ('Mouhib Chamakh', (SELECT id FROM public.teams WHERE code='TUN'), 'GK', 1, 'Club Africain'),
  ('Ali Abdi', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 2, 'Nice'),
  ('Montassar Talbi', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 3, 'Lorient'),
  ('Omar Rekik', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 4, 'Maribor'),
  ('Adem Arous', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 5, 'Kasımpaşa'),
  ('Dylan Bronn', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 6, 'Servette'),
  ('Elias Achouri', (SELECT id FROM public.teams WHERE code='TUN'), 'FW', 7, 'Copenhagen'),
  ('Elias Saad', (SELECT id FROM public.teams WHERE code='TUN'), 'FW', 8, 'Hannover 96'),
  ('Hazem Mastouri', (SELECT id FROM public.teams WHERE code='TUN'), 'FW', 9, 'Dynamo Makhachkala'),
  ('Hannibal Mejbri', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 10, 'Burnley'),
  ('Ismaël Gharbi', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 11, 'FC Augsburg'),
  ('Mortadha Ben Ouanes', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 12, 'Kasımpaşa'),
  ('Rani Khedira', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 13, 'Union Berlin'),
  ('Khalil Ayari', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 14, 'Paris Saint-Germain'),
  ('Hadj Mahmoud', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 15, 'Lugano'),
  ('Aymen Dahmen', (SELECT id FROM public.teams WHERE code='TUN'), 'GK', 16, 'CS Sfaxien'),
  ('Ellyes Skhiri (captain)', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 17, 'Eintracht Frankfurt'),
  ('Rayan Elloumi', (SELECT id FROM public.teams WHERE code='TUN'), 'FW', 18, 'Vancouver Whitecaps FC'),
  ('Firas Chaouat', (SELECT id FROM public.teams WHERE code='TUN'), 'FW', 19, 'Club Africain'),
  ('Yan Valery', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 20, 'Young Boys'),
  ('Mohamed Amine Ben Hamida', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 21, 'Espérance de Tunis'),
  ('Sabri Ben Hessen', (SELECT id FROM public.teams WHERE code='TUN'), 'GK', 22, 'Étoile du Sahel'),
  ('Moutaz Neffati', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 23, 'IFK Norrköping'),
  ('Raed Chikhaoui', (SELECT id FROM public.teams WHERE code='TUN'), 'DF', 24, 'US Monastir'),
  ('Anis Ben Slimane', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 25, 'Norwich City'),
  ('Sebastian Tounekti', (SELECT id FROM public.teams WHERE code='TUN'), 'MF', 26, 'Celtic'),
  ('Thibaut Courtois', (SELECT id FROM public.teams WHERE code='BEL'), 'GK', 1, 'Real Madrid'),
  ('Zeno Debast', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 2, 'Sporting CP'),
  ('Arthur Theate', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 3, 'Eintracht Frankfurt'),
  ('Brandon Mechele', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 4, 'Club Brugge'),
  ('Maxim De Cuyper', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 5, 'Brighton & Hove Albion'),
  ('Axel Witsel', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 6, 'Girona'),
  ('Kevin De Bruyne', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 7, 'Napoli'),
  ('Youri Tielemans (captain)', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 8, 'Aston Villa'),
  ('Romelu Lukaku', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 9, 'Napoli'),
  ('Leandro Trossard', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 10, 'Arsenal'),
  ('Jérémy Doku', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 11, 'Manchester City'),
  ('Senne Lammens', (SELECT id FROM public.teams WHERE code='BEL'), 'GK', 12, 'Manchester United'),
  ('Mike Penders', (SELECT id FROM public.teams WHERE code='BEL'), 'GK', 13, 'Strasbourg'),
  ('Dodi Lukébakio', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 14, 'Benfica'),
  ('Thomas Meunier', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 15, 'Lille'),
  ('Koni De Winter', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 16, 'Milan'),
  ('Charles De Ketelaere', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 17, 'Atalanta'),
  ('Joaquin Seys', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 18, 'Club Brugge'),
  ('Diego Moreira', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 19, 'Strasbourg'),
  ('Hans Vanaken', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 20, 'Club Brugge'),
  ('Timothy Castagne', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 21, 'Fulham'),
  ('Alexis Saelemaekers', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 22, 'Milan'),
  ('Nicolas Raskin', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 23, 'Rangers'),
  ('Amadou Onana', (SELECT id FROM public.teams WHERE code='BEL'), 'MF', 24, 'Aston Villa'),
  ('Nathan Ngoy', (SELECT id FROM public.teams WHERE code='BEL'), 'DF', 25, 'Lille'),
  ('Matias Fernandez-Pardo', (SELECT id FROM public.teams WHERE code='BEL'), 'FW', 26, 'Lille'),
  ('Mohamed El Shenawy', (SELECT id FROM public.teams WHERE code='EGY'), 'GK', 1, 'Al Ahly'),
  ('Yasser Ibrahim', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 2, 'Al Ahly'),
  ('Mohamed Hany', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 3, 'Al Ahly'),
  ('Hossam Abdelmaguid', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 4, 'Zamalek'),
  ('Ramy Rabia', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 5, 'Al Ain'),
  ('Mohamed Abdelmonem', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 6, 'Nice'),
  ('Trézéguet', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 7, 'Al Ahly'),
  ('Emam Ashour', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 8, 'Al Ahly'),
  ('Hamza Abdelkarim', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 9, 'Barcelona B'),
  ('Mohamed Salah (captain)', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 10, 'Liverpool'),
  ('Mostafa Ziko', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 11, 'Pyramids'),
  ('Haissem Hassan', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 12, 'Oviedo'),
  ('Ahmed Fatouh', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 13, 'Zamalek'),
  ('Hamdy Fathy', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 14, 'Al-Wakrah'),
  ('Karim Hafez', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 15, 'Pyramids'),
  ('El Mahdy Soliman', (SELECT id FROM public.teams WHERE code='EGY'), 'GK', 16, 'Zamalek'),
  ('Mohanad Lasheen', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 17, 'Pyramids'),
  ('Nabil Emad', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 18, 'Al-Najma'),
  ('Marwan Attia', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 19, 'Al Ahly'),
  ('Ibrahim Adel', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 20, 'Nordsjælland'),
  ('Mahmoud Saber', (SELECT id FROM public.teams WHERE code='EGY'), 'MF', 21, 'ZED'),
  ('Omar Marmoush', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 22, 'Manchester City'),
  ('Mostafa Shobeir', (SELECT id FROM public.teams WHERE code='EGY'), 'GK', 23, 'Al Ahly'),
  ('Tarek Alaa', (SELECT id FROM public.teams WHERE code='EGY'), 'DF', 24, 'ZED'),
  ('Zizo', (SELECT id FROM public.teams WHERE code='EGY'), 'FW', 25, 'Al Ahly'),
  ('Mohamed Alaa', (SELECT id FROM public.teams WHERE code='EGY'), 'GK', 26, 'El Gouna'),
  ('Alireza Beiranvand', (SELECT id FROM public.teams WHERE code='IRN'), 'GK', 1, 'Tractor'),
  ('Saleh Hardani', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 2, 'Esteghlal'),
  ('Ehsan Hajsafi (captain)', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 3, 'Sepahan'),
  ('Shojae Khalilzadeh', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 4, 'Tractor'),
  ('Milad Mohammadi', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 5, 'Persepolis'),
  ('Saeid Ezatolahi', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 6, 'Shabab Al Ahli'),
  ('Alireza Jahanbakhsh', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 7, 'Dender'),
  ('Mohammad Mohebi', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 8, 'Rostov'),
  ('Mehdi Taremi', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 9, 'Olympiacos'),
  ('Mehdi Ghayedi', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 10, 'Al Nasr'),
  ('Ali Alipour', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 11, 'Persepolis'),
  ('Payam Niazmand', (SELECT id FROM public.teams WHERE code='IRN'), 'GK', 12, 'Persepolis'),
  ('Hossein Kanaanizadegan', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 13, 'Persepolis'),
  ('Saman Ghoddos', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 14, 'Kalba'),
  ('Rouzbeh Cheshmi', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 15, 'Esteghlal'),
  ('Mehdi Torabi', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 16, 'Tractor'),
  ('Aria Yousefi', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 17, 'Sepahan'),
  ('Amirhossein Hosseinzadeh', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 18, 'Tractor'),
  ('Ali Nemati', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 19, 'Foolad'),
  ('Shahriyar Moghanlou', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 20, 'Kalba'),
  ('Mohammad Ghorbani', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 21, 'Al Wahda'),
  ('Hossein Hosseini', (SELECT id FROM public.teams WHERE code='IRN'), 'GK', 22, 'Sepahan'),
  ('Ramin Rezaeian', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 23, 'Foolad'),
  ('Dennis Eckert', (SELECT id FROM public.teams WHERE code='IRN'), 'FW', 24, 'Standard Liège'),
  ('Danial Eiri', (SELECT id FROM public.teams WHERE code='IRN'), 'DF', 25, 'Malavan'),
  ('Amirmohammad Razzaghinia', (SELECT id FROM public.teams WHERE code='IRN'), 'MF', 26, 'Esteghlal'),
  ('Max Crocombe', (SELECT id FROM public.teams WHERE code='NZL'), 'GK', 1, 'Millwall'),
  ('Tim Payne', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 2, 'Wellington Phoenix'),
  ('Francis de Vries', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 3, 'Auckland FC'),
  ('Tyler Bindon', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 4, 'Sheffield United'),
  ('Michael Boxall', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 5, 'Minnesota United FC'),
  ('Joe Bell', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 6, 'Viking'),
  ('Matthew Garbett', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 7, 'Peterborough United'),
  ('Marko Stamenić', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 8, 'Swansea City'),
  ('Chris Wood (captain)', (SELECT id FROM public.teams WHERE code='NZL'), 'FW', 9, 'Nottingham Forest'),
  ('Sarpreet Singh', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 10, 'Wellington Phoenix'),
  ('Elijah Just', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 11, 'Motherwell'),
  ('Alex Paulsen', (SELECT id FROM public.teams WHERE code='NZL'), 'GK', 12, 'Lechia Gdańsk'),
  ('Liberato Cacace', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 13, 'Wrexham'),
  ('Alex Rufer', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 14, 'Wellington Phoenix'),
  ('Nando Pijnaker', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 15, 'Auckland FC'),
  ('Finn Surman', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 16, 'Portland Timbers'),
  ('Kosta Barbarouses', (SELECT id FROM public.teams WHERE code='NZL'), 'FW', 17, 'Western Sydney Wanderers'),
  ('Ben Waine', (SELECT id FROM public.teams WHERE code='NZL'), 'FW', 18, 'Port Vale'),
  ('Ben Old', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 19, 'Saint-Étienne'),
  ('Callum McCowatt', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 20, 'Silkeborg'),
  ('Jesse Randall', (SELECT id FROM public.teams WHERE code='NZL'), 'FW', 21, 'Auckland FC'),
  ('Michael Woud', (SELECT id FROM public.teams WHERE code='NZL'), 'GK', 22, 'Auckland FC'),
  ('Ryan Thomas', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 23, 'PEC Zwolle'),
  ('Callan Elliot', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 24, 'Auckland FC'),
  ('Lachlan Bayliss', (SELECT id FROM public.teams WHERE code='NZL'), 'MF', 25, 'Newcastle Jets'),
  ('Tommy Smith', (SELECT id FROM public.teams WHERE code='NZL'), 'DF', 26, 'Braintree Town'),
  ('Vozinha', (SELECT id FROM public.teams WHERE code='CPV'), 'GK', 1, 'Chaves'),
  ('Stopira', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 2, 'Torreense'),
  ('Diney', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 3, 'Al Bataeh'),
  ('Roberto Lopes', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 4, 'Shamrock Rovers'),
  ('Logan Costa', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 5, 'Villarreal'),
  ('Kevin Pina', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 6, 'Krasnodar'),
  ('Jovane Cabral', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 7, 'Estrela Amadora'),
  ('João Paulo', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 8, 'FCSB'),
  ('Gilson Benchimol', (SELECT id FROM public.teams WHERE code='CPV'), 'FW', 9, 'Akron Tolyatti'),
  ('Jamiro Monteiro', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 10, 'PEC Zwolle'),
  ('Garry Rodrigues', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 11, 'Apollon Limassol'),
  ('Márcio Rosa', (SELECT id FROM public.teams WHERE code='CPV'), 'GK', 12, 'Montana'),
  ('Sidny Lopes Cabral', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 13, 'Benfica'),
  ('Deroy Duarte', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 14, 'Ludogorets Razgrad'),
  ('Laros Duarte', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 15, 'Puskás Akadémia'),
  ('Yannick Semedo', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 16, 'Farense'),
  ('Willy Semedo', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 17, 'Omonia'),
  ('Telmo Arcanjo', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 18, 'Vitória de Guimarães'),
  ('Dailon Livramento', (SELECT id FROM public.teams WHERE code='CPV'), 'FW', 19, 'Casa Pia'),
  ('Ryan Mendes (captain)', (SELECT id FROM public.teams WHERE code='CPV'), 'FW', 20, 'Iğdır'),
  ('Nuno da Costa', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 21, 'İstanbul Başakşehir'),
  ('Steven Moreira', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 22, 'Columbus Crew'),
  ('CJ dos Santos', (SELECT id FROM public.teams WHERE code='CPV'), 'GK', 23, 'San Diego FC'),
  ('Wagner Pina', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 24, 'Trabzonspor'),
  ('Kelvin Pires', (SELECT id FROM public.teams WHERE code='CPV'), 'DF', 25, 'SJK'),
  ('Hélio Varela', (SELECT id FROM public.teams WHERE code='CPV'), 'MF', 26, 'Maccabi Tel Aviv'),
  ('Nawaf Al-Aqidi', (SELECT id FROM public.teams WHERE code='KSA'), 'GK', 1, 'Al-Nassr'),
  ('Ali Majrashi', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 2, 'Al-Ahli'),
  ('Ali Lajami', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 3, 'Al-Hilal'),
  ('Abdulelah Al-Amri', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 4, 'Al-Nassr'),
  ('Hassan Al-Tambakti', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 5, 'Al-Hilal'),
  ('Nasser Al-Dawsari', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 6, 'Al-Hilal'),
  ('Musab Al-Juwayr', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 7, 'Al-Qadsiah'),
  ('Ayman Yahya', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 8, 'Al-Nassr'),
  ('Firas Al-Buraikan', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 9, 'Al-Ahli'),
  ('Salem Al-Dawsari (captain)', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 10, 'Al-Hilal'),
  ('Saleh Al-Shehri', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 11, 'Al-Ittihad'),
  ('Saud Abdulhamid', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 12, 'Lens'),
  ('Nawaf Boushal', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 13, 'Al-Nassr'),
  ('Hassan Kadesh', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 14, 'Al-Ittihad'),
  ('Abdullah Al-Khaibari', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 15, 'Al-Nassr'),
  ('Ziyad Al-Johani', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 16, 'Al-Ahli'),
  ('Khalid Al-Ghannam', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 17, 'Al-Ettifaq'),
  ('Alaa Al-Hejji', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 18, 'Neom'),
  ('Abdullah Al-Hamdan', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 19, 'Al-Nassr'),
  ('Sultan Mandash', (SELECT id FROM public.teams WHERE code='KSA'), 'FW', 20, 'Al-Hilal'),
  ('Mohammed Al-Owais', (SELECT id FROM public.teams WHERE code='KSA'), 'GK', 21, 'Al-Ula'),
  ('Ahmed Al-Kassar', (SELECT id FROM public.teams WHERE code='KSA'), 'GK', 22, 'Al-Qadsiah'),
  ('Mohamed Kanno', (SELECT id FROM public.teams WHERE code='KSA'), 'MF', 23, 'Al-Hilal'),
  ('Moteb Al-Harbi', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 24, 'Al-Hilal'),
  ('Jehad Thakri', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 25, 'Al-Qadsiah'),
  ('Mohammed Abu Al-Shamat', (SELECT id FROM public.teams WHERE code='KSA'), 'DF', 26, 'Al-Qadsiah'),
  ('David Raya', (SELECT id FROM public.teams WHERE code='ESP'), 'GK', 1, 'Arsenal'),
  ('Marc Pubill', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 2, 'Atlético Madrid'),
  ('Álex Grimaldo', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 3, 'Bayer Leverkusen'),
  ('Eric García', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 4, 'Barcelona'),
  ('Marcos Llorente', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 5, 'Atlético Madrid'),
  ('Mikel Merino', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 6, 'Arsenal'),
  ('Ferran Torres', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 7, 'Barcelona'),
  ('Fabián Ruiz', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 8, 'Paris Saint-Germain'),
  ('Gavi', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 9, 'Barcelona'),
  ('Dani Olmo', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 10, 'Barcelona'),
  ('Yéremy Pino', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 11, 'Crystal Palace'),
  ('Pedro Porro', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 12, 'Tottenham Hotspur'),
  ('Joan Garcia', (SELECT id FROM public.teams WHERE code='ESP'), 'GK', 13, 'Barcelona'),
  ('Aymeric Laporte', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 14, 'Athletic Bilbao'),
  ('Álex Baena', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 15, 'Atlético Madrid'),
  ('Rodri (captain)', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 16, 'Manchester City'),
  ('Nico Williams', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 17, 'Athletic Bilbao'),
  ('Martín Zubimendi', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 18, 'Arsenal'),
  ('Lamine Yamal', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 19, 'Barcelona'),
  ('Pedri', (SELECT id FROM public.teams WHERE code='ESP'), 'MF', 20, 'Barcelona'),
  ('Mikel Oyarzabal', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 21, 'Real Sociedad'),
  ('Pau Cubarsí', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 22, 'Barcelona'),
  ('Unai Simón', (SELECT id FROM public.teams WHERE code='ESP'), 'GK', 23, 'Athletic Bilbao'),
  ('Marc Cucurella', (SELECT id FROM public.teams WHERE code='ESP'), 'DF', 24, 'Chelsea'),
  ('Víctor Muñoz', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 25, 'Osasuna'),
  ('Borja Iglesias', (SELECT id FROM public.teams WHERE code='ESP'), 'FW', 26, 'Celta Vigo'),
  ('Sergio Rochet', (SELECT id FROM public.teams WHERE code='URU'), 'GK', 1, 'Internacional'),
  ('José Giménez (captain)', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 2, 'Atlético Madrid'),
  ('Sebastián Cáceres', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 3, 'América'),
  ('Ronald Araújo', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 4, 'Barcelona'),
  ('Manuel Ugarte', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 5, 'Manchester United'),
  ('Rodrigo Bentancur', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 6, 'Tottenham Hotspur'),
  ('Nicolás de la Cruz', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 7, 'Flamengo'),
  ('Federico Valverde', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 8, 'Real Madrid'),
  ('Darwin Núñez', (SELECT id FROM public.teams WHERE code='URU'), 'FW', 9, 'Al-Hilal'),
  ('Giorgian de Arrascaeta', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 10, 'Flamengo'),
  ('Facundo Pellistri', (SELECT id FROM public.teams WHERE code='URU'), 'FW', 11, 'Panathinaikos'),
  ('Santiago Mele', (SELECT id FROM public.teams WHERE code='URU'), 'GK', 12, 'Monterrey'),
  ('Guillermo Varela', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 13, 'Flamengo'),
  ('Agustín Canobbio', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 14, 'Fluminense'),
  ('Emiliano Martínez', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 15, 'Palmeiras'),
  ('Mathías Olivera', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 16, 'Napoli'),
  ('Matías Viña', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 17, 'River Plate'),
  ('Brian Rodríguez', (SELECT id FROM public.teams WHERE code='URU'), 'FW', 18, 'América'),
  ('Rodrigo Aguirre', (SELECT id FROM public.teams WHERE code='URU'), 'FW', 19, 'UANL'),
  ('Maximiliano Araújo', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 20, 'Sporting CP'),
  ('Federico Viñas', (SELECT id FROM public.teams WHERE code='URU'), 'FW', 21, 'Oviedo'),
  ('Joaquín Piquerez', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 22, 'Palmeiras'),
  ('Fernando Muslera', (SELECT id FROM public.teams WHERE code='URU'), 'GK', 23, 'Estudiantes'),
  ('Santiago Bueno', (SELECT id FROM public.teams WHERE code='URU'), 'DF', 24, 'Wolverhampton Wanderers'),
  ('Juan Manuel Sanabria', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 25, 'Real Salt Lake'),
  ('Rodrigo Zalazar', (SELECT id FROM public.teams WHERE code='URU'), 'MF', 26, 'Braga'),
  ('Brice Samba', (SELECT id FROM public.teams WHERE code='FRA'), 'GK', 1, 'Rennes'),
  ('Malo Gusto', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 2, 'Chelsea'),
  ('Lucas Digne', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 3, 'Aston Villa'),
  ('Dayot Upamecano', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 4, 'Bayern Munich'),
  ('Jules Koundé', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 5, 'Barcelona'),
  ('Manu Koné', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 6, 'Roma'),
  ('Ousmane Dembélé', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 7, 'Paris Saint-Germain'),
  ('Aurélien Tchouaméni', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 8, 'Real Madrid'),
  ('Marcus Thuram', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 9, 'Inter Milan'),
  ('Kylian Mbappé (captain)', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 10, 'Real Madrid'),
  ('Michael Olise', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 11, 'Bayern Munich'),
  ('Bradley Barcola', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 12, 'Paris Saint-Germain'),
  ('N''Golo Kanté', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 13, 'Fenerbahçe'),
  ('Adrien Rabiot', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 14, 'Milan'),
  ('Ibrahima Konaté', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 15, 'Liverpool'),
  ('Mike Maignan', (SELECT id FROM public.teams WHERE code='FRA'), 'GK', 16, 'Milan'),
  ('William Saliba', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 17, 'Arsenal'),
  ('Warren Zaïre-Emery', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 18, 'Paris Saint-Germain'),
  ('Théo Hernandez', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 19, 'Al-Hilal'),
  ('Désiré Doué', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 20, 'Paris Saint-Germain'),
  ('Lucas Hernandez', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 21, 'Paris Saint-Germain'),
  ('Jean-Philippe Mateta', (SELECT id FROM public.teams WHERE code='FRA'), 'FW', 22, 'Crystal Palace'),
  ('Robin Risser', (SELECT id FROM public.teams WHERE code='FRA'), 'GK', 23, 'Lens'),
  ('Rayan Cherki', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 24, 'Manchester City'),
  ('Maghnes Akliouche', (SELECT id FROM public.teams WHERE code='FRA'), 'MF', 25, 'Monaco'),
  ('Maxence Lacroix', (SELECT id FROM public.teams WHERE code='FRA'), 'DF', 26, 'Crystal Palace'),
  ('Fahad Talib', (SELECT id FROM public.teams WHERE code='IRQ'), 'GK', 1, 'Al-Talaba'),
  ('Rebin Sulaka', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 2, 'Port'),
  ('Hussein Ali', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 3, 'Pogoń Szczecin'),
  ('Zaid Tahseen', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 4, 'Pakhtakor'),
  ('Akam Hashim', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 5, 'Al-Zawraa'),
  ('Manaf Younis', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 6, 'Al-Shorta'),
  ('Youssef Amyn', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 7, 'AEK Larnaca'),
  ('Ibrahim Bayesh', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 8, 'Al Dhafra'),
  ('Ali Al-Hamadi', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 9, 'Luton Town'),
  ('Mohanad Ali', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 10, 'Dibba'),
  ('Ahmed Qasem', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 11, 'Nashville SC'),
  ('Jalal Hassan (captain)', (SELECT id FROM public.teams WHERE code='IRQ'), 'GK', 12, 'Al-Zawraa'),
  ('Ali Yousif', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 13, 'Al-Talaba'),
  ('Zidane Iqbal', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 14, 'Utrecht'),
  ('Ahmed Maknzi', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 15, 'Al-Karma'),
  ('Amir Al-Ammari', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 16, 'Cracovia'),
  ('Ali Jasim', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 17, 'Al-Najma'),
  ('Aymen Hussein', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 18, 'Al-Karma'),
  ('Kevin Yakob', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 19, 'AGF'),
  ('Aimar Sher', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 20, 'Sarpsborg 08'),
  ('Marko Farji', (SELECT id FROM public.teams WHERE code='IRQ'), 'FW', 21, 'Venezia'),
  ('Ahmed Basil', (SELECT id FROM public.teams WHERE code='IRQ'), 'GK', 22, 'Al-Shorta'),
  ('Merchas Doski', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 23, 'Viktoria Plzeň'),
  ('Zaid Ismail', (SELECT id FROM public.teams WHERE code='IRQ'), 'MF', 24, 'Al-Talaba'),
  ('Mustafa Saadoon', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 25, 'Al-Shorta'),
  ('Frans Putros', (SELECT id FROM public.teams WHERE code='IRQ'), 'DF', 26, 'Persib'),
  ('Ørjan Nyland', (SELECT id FROM public.teams WHERE code='NOR'), 'GK', 1, 'Sevilla'),
  ('Morten Thorsby', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 2, 'Cremonese'),
  ('Kristoffer Ajer', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 3, 'Brentford'),
  ('Leo Østigård', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 4, 'Genoa'),
  ('David Møller Wolfe', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 5, 'Wolverhampton Wanderers'),
  ('Patrick Berg', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 6, 'Bodø/Glimt'),
  ('Alexander Sørloth', (SELECT id FROM public.teams WHERE code='NOR'), 'FW', 7, 'Atlético Madrid'),
  ('Sander Berge', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 8, 'Fulham'),
  ('Erling Haaland', (SELECT id FROM public.teams WHERE code='NOR'), 'FW', 9, 'Manchester City'),
  ('Martin Ødegaard (captain)', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 10, 'Arsenal'),
  ('Jørgen Strand Larsen', (SELECT id FROM public.teams WHERE code='NOR'), 'FW', 11, 'Crystal Palace'),
  ('Sander Tangvik', (SELECT id FROM public.teams WHERE code='NOR'), 'GK', 12, 'Hamburger SV'),
  ('Egil Selvik', (SELECT id FROM public.teams WHERE code='NOR'), 'GK', 13, 'Watford'),
  ('Fredrik Aursnes', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 14, 'Benfica'),
  ('Fredrik André Bjørkan', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 15, 'Bodø/Glimt'),
  ('Marcus Holmgren Pedersen', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 16, 'Torino'),
  ('Torbjørn Heggem', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 17, 'Bologna'),
  ('Kristian Thorstvedt', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 18, 'Sassuolo'),
  ('Thelo Aasgaard', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 19, 'Rangers'),
  ('Antonio Nusa', (SELECT id FROM public.teams WHERE code='NOR'), 'FW', 20, 'RB Leipzig'),
  ('Andreas Schjelderup', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 21, 'Benfica'),
  ('Oscar Bobb', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 22, 'Fulham'),
  ('Jens Petter Hauge', (SELECT id FROM public.teams WHERE code='NOR'), 'MF', 23, 'Bodø/Glimt'),
  ('Sondre Langås', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 24, 'Derby County'),
  ('Henrik Falchener', (SELECT id FROM public.teams WHERE code='NOR'), 'DF', 25, 'Viking'),
  ('Julian Ryerson', (SELECT id FROM public.teams WHERE code='NOR'), 'FW', 26, 'Borussia Dortmund'),
  ('Yehvann Diouf', (SELECT id FROM public.teams WHERE code='SEN'), 'GK', 1, 'Nice'),
  ('Mamadou Sarr', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 2, 'Chelsea'),
  ('Kalidou Koulibaly (captain)', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 3, 'Al-Hilal'),
  ('Abdoulaye Seck', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 4, 'Maccabi Haifa'),
  ('Idrissa Gueye', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 5, 'Everton'),
  ('Pathé Ciss', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 6, 'Rayo Vallecano'),
  ('Assane Diao', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 7, 'Como'),
  ('Lamine Camara', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 8, 'Monaco'),
  ('Bamba Dieng', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 9, 'Lorient'),
  ('Sadio Mané', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 10, 'Al-Nassr'),
  ('Nicolas Jackson', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 11, 'Bayern Munich'),
  ('Cherif Ndiaye', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 12, 'Samsunspor'),
  ('Iliman Ndiaye', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 13, 'Everton'),
  ('Ismail Jakobs', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 14, 'Galatasaray'),
  ('Krépin Diatta', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 15, 'Monaco'),
  ('Édouard Mendy', (SELECT id FROM public.teams WHERE code='SEN'), 'GK', 16, 'Al-Ahli'),
  ('Pape Matar Sarr', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 17, 'Tottenham Hotspur'),
  ('Ismaïla Sarr', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 18, 'Crystal Palace'),
  ('Moussa Niakhaté', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 19, 'Lyon'),
  ('Ibrahim Mbaye', (SELECT id FROM public.teams WHERE code='SEN'), 'FW', 20, 'Paris Saint-Germain'),
  ('Habib Diarra', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 21, 'Sunderland'),
  ('Bara Sapoko Ndiaye', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 22, 'Bayern Munich'),
  ('Mory Diaw', (SELECT id FROM public.teams WHERE code='SEN'), 'GK', 23, 'Le Havre'),
  ('Antoine Mendy', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 24, 'Nice'),
  ('El Hadji Malick Diouf', (SELECT id FROM public.teams WHERE code='SEN'), 'DF', 25, 'West Ham United'),
  ('Pape Gueye', (SELECT id FROM public.teams WHERE code='SEN'), 'MF', 26, 'Villarreal'),
  ('Melvin Mastil', (SELECT id FROM public.teams WHERE code='ALG'), 'GK', 1, 'Stade Nyonnais'),
  ('Aïssa Mandi', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 2, 'Lille'),
  ('Achref Abada', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 3, 'USM Alger'),
  ('Mohamed Amine Tougai', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 4, 'Espérance de Tunis'),
  ('Zineddine Belaïd', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 5, 'JS Kabylie'),
  ('Ramiz Zerrouki', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 6, 'Twente'),
  ('Riyad Mahrez (captain)', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 7, 'Al-Ahli'),
  ('Houssem Aouar', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 8, 'Al-Ittihad'),
  ('Amine Gouiri', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 9, 'Marseille'),
  ('Farès Chaïbi', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 10, 'Eintracht Frankfurt'),
  ('Anis Hadj Moussa', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 11, 'Feyenoord'),
  ('Nadhir Benbouali', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 12, 'Győri ETO'),
  ('Jaouen Hadjam', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 13, 'Young Boys'),
  ('Hicham Boudaoui', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 14, 'Nice'),
  ('Rayan Aït-Nouri', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 15, 'Manchester City'),
  ('Oussama Benbot', (SELECT id FROM public.teams WHERE code='ALG'), 'GK', 16, 'USM Alger'),
  ('Rafik Belghali', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 17, 'Hellas Verona'),
  ('Mohamed Amoura', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 18, 'VfL Wolfsburg'),
  ('Nabil Bentaleb', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 19, 'Lille'),
  ('Adil Boulbina', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 20, 'Al-Duhail'),
  ('Ramy Bensebaini', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 21, 'Borussia Dortmund'),
  ('Ibrahim Maza', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 22, 'Bayer Leverkusen'),
  ('Luca Zidane', (SELECT id FROM public.teams WHERE code='ALG'), 'GK', 23, 'Granada'),
  ('Yacine Titraoui', (SELECT id FROM public.teams WHERE code='ALG'), 'MF', 24, 'Charleroi'),
  ('Farès Ghedjemis', (SELECT id FROM public.teams WHERE code='ALG'), 'FW', 25, 'Frosinone'),
  ('Samir Chergui', (SELECT id FROM public.teams WHERE code='ALG'), 'DF', 26, 'Paris FC'),
  ('Juan Musso', (SELECT id FROM public.teams WHERE code='ARG'), 'GK', 1, 'Atlético Madrid'),
  ('Nicolás Tagliafico', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 3, 'Lyon'),
  ('Gonzalo Montiel', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 4, 'River Plate'),
  ('Leandro Paredes', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 5, 'Boca Juniors'),
  ('Lisandro Martínez', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 6, 'Manchester United'),
  ('Rodrigo De Paul', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 7, 'Inter Miami CF'),
  ('Valentín Barco', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 8, 'Strasbourg'),
  ('Julián Alvarez', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 9, 'Atlético Madrid'),
  ('Lionel Messi (captain)', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 10, 'Inter Miami CF'),
  ('Giovani Lo Celso', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 11, 'Real Betis'),
  ('Gerónimo Rulli', (SELECT id FROM public.teams WHERE code='ARG'), 'GK', 12, 'Marseille'),
  ('Cristian Romero', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 13, 'Tottenham Hotspur'),
  ('Exequiel Palacios', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 14, 'Bayer Leverkusen'),
  ('Nicolás González', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 15, 'Atlético Madrid'),
  ('Thiago Almada', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 16, 'Atlético Madrid'),
  ('Giuliano Simeone', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 17, 'Atlético Madrid'),
  ('Nico Paz', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 18, 'Como'),
  ('Nicolás Otamendi', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 19, 'Benfica'),
  ('Alexis Mac Allister', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 20, 'Liverpool'),
  ('José Manuel López', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 21, 'Palmeiras'),
  ('Lautaro Martínez', (SELECT id FROM public.teams WHERE code='ARG'), 'FW', 22, 'Inter Milan'),
  ('Emiliano Martínez', (SELECT id FROM public.teams WHERE code='ARG'), 'GK', 23, 'Aston Villa'),
  ('Enzo Fernández', (SELECT id FROM public.teams WHERE code='ARG'), 'MF', 24, 'Chelsea'),
  ('Facundo Medina', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 25, 'Marseille'),
  ('Nahuel Molina', (SELECT id FROM public.teams WHERE code='ARG'), 'DF', 26, 'Atlético Madrid'),
  ('Alexander Schlager', (SELECT id FROM public.teams WHERE code='AUT'), 'GK', 1, 'Red Bull Salzburg'),
  ('David Affengruber', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 2, 'Elche'),
  ('Kevin Danso', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 3, 'Tottenham Hotspur'),
  ('Xaver Schlager', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 4, 'RB Leipzig'),
  ('Stefan Posch', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 5, 'Mainz 05'),
  ('Nicolas Seiwald', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 6, 'RB Leipzig'),
  ('Marko Arnautović', (SELECT id FROM public.teams WHERE code='AUT'), 'FW', 7, 'Red Star Belgrade'),
  ('David Alaba (captain)', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 8, 'Real Madrid'),
  ('Marcel Sabitzer', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 9, 'Borussia Dortmund'),
  ('Florian Grillitsch', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 10, 'Braga'),
  ('Michael Gregoritsch', (SELECT id FROM public.teams WHERE code='AUT'), 'FW', 11, 'FC Augsburg'),
  ('Florian Wiegele', (SELECT id FROM public.teams WHERE code='AUT'), 'GK', 12, 'Viktoria Plzeň'),
  ('Patrick Pentz', (SELECT id FROM public.teams WHERE code='AUT'), 'GK', 13, 'Brøndby'),
  ('Saša Kalajdžić', (SELECT id FROM public.teams WHERE code='AUT'), 'FW', 14, 'LASK'),
  ('Philipp Lienhart', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 15, 'SC Freiburg'),
  ('Phillipp Mwene', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 16, 'Mainz 05'),
  ('Carney Chukwuemeka', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 17, 'Borussia Dortmund'),
  ('Romano Schmid', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 18, 'Werder Bremen'),
  ('Konrad Laimer', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 20, 'Bayern Munich'),
  ('Patrick Wimmer', (SELECT id FROM public.teams WHERE code='AUT'), 'FW', 21, 'VfL Wolfsburg'),
  ('Alexander Prass', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 22, 'TSG Hoffenheim'),
  ('Marco Friedl', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 23, 'Werder Bremen'),
  ('Paul Wanner', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 24, 'PSV Eindhoven'),
  ('Michael Svoboda', (SELECT id FROM public.teams WHERE code='AUT'), 'DF', 25, 'Venezia'),
  ('Alessandro Schöpf', (SELECT id FROM public.teams WHERE code='AUT'), 'MF', 26, 'Wolfsberger AC'),
  ('Yazeed Abulaila', (SELECT id FROM public.teams WHERE code='JOR'), 'GK', 1, 'Al-Hussein'),
  ('Mohammad Abu Hashish', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 2, 'Al-Karma'),
  ('Abdallah Nasib', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 3, 'Al-Zawraa'),
  ('Husam Abu Dahab', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 4, 'Al-Faisaly'),
  ('Yazan Al-Arab', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 5, 'FC Seoul'),
  ('Amer Jamous', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 6, 'Al-Zawraa'),
  ('Mohammad Abu Zrayq', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 7, 'Raja Casablanca'),
  ('Noor Al-Rawabdeh', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 8, 'Selangor'),
  ('Ali Olwan', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 9, 'Al-Sailiya'),
  ('Musa Al-Taamari', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 10, 'Rennes'),
  ('Odeh Al-Fakhouri', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 11, 'Pyramids'),
  ('Nour Bani Attiah', (SELECT id FROM public.teams WHERE code='JOR'), 'GK', 12, 'Al-Faisaly'),
  ('Mahmoud Al-Mardi', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 13, 'Al-Hussein'),
  ('Rajaei Ayed', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 14, 'Al-Hussein'),
  ('Ibrahim Sadeh', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 15, 'Al-Karma'),
  ('Mo Abualnadi', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 16, 'Selangor'),
  ('Salim Obaid', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 17, 'Al-Hussein'),
  ('Mohammad Taha', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 18, 'Al-Hussein'),
  ('Saed Al-Rosan', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 19, 'Al-Hussein'),
  ('Mohannad Abu Taha', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 20, 'Al-Quwa Al-Jawiya'),
  ('Nizar Al-Rashdan', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 21, 'Qatar SC'),
  ('Abdallah Al-Fakhouri', (SELECT id FROM public.teams WHERE code='JOR'), 'GK', 22, 'Al-Wehdat'),
  ('Ihsan Haddad (captain)', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 23, 'Al-Hussein'),
  ('Ali Azaizeh', (SELECT id FROM public.teams WHERE code='JOR'), 'FW', 24, 'Al-Shabab'),
  ('Mohammad Al-Dawoud', (SELECT id FROM public.teams WHERE code='JOR'), 'MF', 25, 'Al-Wehdat'),
  ('Anas Badawi', (SELECT id FROM public.teams WHERE code='JOR'), 'DF', 26, 'Al-Faisaly'),
  ('David Ospina', (SELECT id FROM public.teams WHERE code='COL'), 'GK', 1, 'Atlético Nacional'),
  ('Daniel Muñoz', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 2, 'Crystal Palace'),
  ('Jhon Lucumí', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 3, 'Bologna'),
  ('Santiago Arias', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 4, 'Independiente'),
  ('Kevin Castaño', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 5, 'River Plate'),
  ('Richard Ríos', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 6, 'Benfica'),
  ('Luis Díaz', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 7, 'Bayern Munich'),
  ('Jorge Carrascal', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 8, 'Flamengo'),
  ('Jhon Córdoba', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 9, 'Krasnodar'),
  ('James Rodríguez (captain)', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 10, 'Minnesota United FC'),
  ('Jhon Arias', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 11, 'Palmeiras'),
  ('Camilo Vargas', (SELECT id FROM public.teams WHERE code='COL'), 'GK', 12, 'Atlas'),
  ('Yerry Mina', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 13, 'Cagliari'),
  ('Gustavo Puerta', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 14, 'Racing Santander'),
  ('Juan Portilla', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 15, 'Athletico Paranaense'),
  ('Jefferson Lerma', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 16, 'Crystal Palace'),
  ('Johan Mojica', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 17, 'Mallorca'),
  ('Willer Ditta', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 18, 'Cruz Azul'),
  ('Cucho Hernández', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 19, 'Real Betis'),
  ('Juan Fernando Quintero', (SELECT id FROM public.teams WHERE code='COL'), 'MF', 20, 'River Plate'),
  ('Jaminton Campaz', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 21, 'Rosario Central'),
  ('Deiver Machado', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 22, 'Nantes'),
  ('Davinson Sánchez', (SELECT id FROM public.teams WHERE code='COL'), 'DF', 23, 'Galatasaray'),
  ('Álvaro Montero', (SELECT id FROM public.teams WHERE code='COL'), 'GK', 24, 'Vélez Sarsfield'),
  ('Luis Suárez', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 25, 'Sporting CP'),
  ('Andrés Gómez', (SELECT id FROM public.teams WHERE code='COL'), 'FW', 26, 'Vasco da Gama'),
  ('Lionel Mpasi', (SELECT id FROM public.teams WHERE code='COD'), 'GK', 1, 'Le Havre'),
  ('Aaron Wan-Bissaka', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 2, 'West Ham United'),
  ('Steve Kapuadi', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 3, 'Widzew Łódź'),
  ('Axel Tuanzebe', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 4, 'Burnley'),
  ('Dylan Batubinsika', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 5, 'AEL'),
  ('Ngal''ayel Mukau', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 6, 'Lille'),
  ('Nathanaël Mbuku', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 7, 'Montpellier'),
  ('Samuel Moutoussamy', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 8, 'Atromitos'),
  ('Brian Cipenga', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 9, 'Castellón'),
  ('Théo Bongonda', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 10, 'Spartak Moscow'),
  ('Gaël Kakuta', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 11, 'AEL'),
  ('Joris Kayembe', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 12, 'Genk'),
  ('Meschak Elia', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 13, 'Alanyaspor'),
  ('Noah Sadiki', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 14, 'Sunderland'),
  ('Aaron Tshibola', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 15, 'Kilmarnock'),
  ('Timothy Fayulu', (SELECT id FROM public.teams WHERE code='COD'), 'GK', 16, 'Noah'),
  ('Cédric Bakambu', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 17, 'Real Betis'),
  ('Charles Pickel', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 18, 'Espanyol'),
  ('Fiston Mayele', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 19, 'Pyramids'),
  ('Yoane Wissa', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 20, 'Newcastle United'),
  ('Matthieu Epolo', (SELECT id FROM public.teams WHERE code='COD'), 'GK', 21, 'Standard Liège'),
  ('Chancel Mbemba (captain)', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 22, 'Lille'),
  ('Simon Banza', (SELECT id FROM public.teams WHERE code='COD'), 'FW', 23, 'Al Jazira'),
  ('Gédéon Kalulu', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 24, 'Aris Limassol'),
  ('Edo Kayembe', (SELECT id FROM public.teams WHERE code='COD'), 'MF', 25, 'Watford'),
  ('Arthur Masuaku', (SELECT id FROM public.teams WHERE code='COD'), 'DF', 26, 'Lens'),
  ('Diogo Costa', (SELECT id FROM public.teams WHERE code='POR'), 'GK', 1, 'Porto'),
  ('Nélson Semedo', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 2, 'Fenerbahçe'),
  ('Rúben Dias', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 3, 'Manchester City'),
  ('Tomás Araújo', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 4, 'Benfica'),
  ('Diogo Dalot', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 5, 'Manchester United'),
  ('Matheus Nunes', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 6, 'Manchester City'),
  ('Cristiano Ronaldo (captain)', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 7, 'Al-Nassr'),
  ('Bruno Fernandes', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 8, 'Manchester United'),
  ('Gonçalo Ramos', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 9, 'Paris Saint-Germain'),
  ('Bernardo Silva', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 10, 'Manchester City'),
  ('João Félix', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 11, 'Al-Nassr'),
  ('José Sá', (SELECT id FROM public.teams WHERE code='POR'), 'GK', 12, 'Wolverhampton Wanderers'),
  ('Renato Veiga', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 13, 'Villarreal'),
  ('Gonçalo Inácio', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 14, 'Sporting CP'),
  ('João Neves', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 15, 'Paris Saint-Germain'),
  ('Francisco Trincão', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 16, 'Sporting CP'),
  ('Rafael Leão', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 17, 'Milan'),
  ('Pedro Neto', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 18, 'Chelsea'),
  ('Gonçalo Guedes', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 19, 'Real Sociedad'),
  ('João Cancelo', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 20, 'Barcelona'),
  ('Rúben Neves', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 21, 'Al-Hilal'),
  ('Rui Silva', (SELECT id FROM public.teams WHERE code='POR'), 'GK', 22, 'Sporting CP'),
  ('Vitinha', (SELECT id FROM public.teams WHERE code='POR'), 'MF', 23, 'Paris Saint-Germain'),
  ('Samú Costa', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 24, 'Mallorca'),
  ('Nuno Mendes', (SELECT id FROM public.teams WHERE code='POR'), 'DF', 25, 'Paris Saint-Germain'),
  ('Francisco Conceição', (SELECT id FROM public.teams WHERE code='POR'), 'FW', 26, 'Juventus'),
  ('Utkir Yusupov', (SELECT id FROM public.teams WHERE code='UZB'), 'GK', 1, 'Navbahor Namangan'),
  ('Abdukodir Khusanov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 2, 'Manchester City'),
  ('Khojiakbar Alijonov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 3, 'Pakhtakor'),
  ('Farrukh Sayfiev', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 4, 'Neftchi Fergana'),
  ('Rustam Ashurmatov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 5, 'Esteghlal'),
  ('Akmal Mozgovoy', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 6, 'Pakhtakor'),
  ('Otabek Shukurov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 7, 'Baniyas'),
  ('Jamshid Iskanderov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 8, 'Neftchi Fergana'),
  ('Odiljon Hamrobekov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 9, 'Tractor'),
  ('Jaloliddin Masharipov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 10, 'Esteghlal'),
  ('Oston Urunov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 11, 'Persepolis'),
  ('Abduvohid Nematov', (SELECT id FROM public.teams WHERE code='UZB'), 'GK', 12, 'Nasaf'),
  ('Sherzod Nasrullaev', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 13, 'Nasaf'),
  ('Eldor Shomurodov (captain)', (SELECT id FROM public.teams WHERE code='UZB'), 'FW', 14, 'İstanbul Başakşehir'),
  ('Umar Eshmurodov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 15, 'Nasaf'),
  ('Botirali Ergashev', (SELECT id FROM public.teams WHERE code='UZB'), 'GK', 16, 'Neftchi Fergana'),
  ('Dostonbek Khamdamov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 17, 'Pakhtakor'),
  ('Abdulla Abdullaev', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 18, 'Dibba'),
  ('Azizjon Ganiev', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 19, 'Al Bataeh'),
  ('Azizbek Amonov', (SELECT id FROM public.teams WHERE code='UZB'), 'FW', 20, 'Dinamo Samarqand'),
  ('Igor Sergeev', (SELECT id FROM public.teams WHERE code='UZB'), 'FW', 21, 'Persepolis'),
  ('Abbosbek Fayzullaev', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 22, 'İstanbul Başakşehir'),
  ('Sherzod Esanov', (SELECT id FROM public.teams WHERE code='UZB'), 'MF', 23, 'Bukhara'),
  ('Bekhruz Karimov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 24, 'Surkhon Termiz'),
  ('Avazbek Ulmasaliev', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 25, 'AGMK'),
  ('Jakhongir Urozov', (SELECT id FROM public.teams WHERE code='UZB'), 'DF', 26, 'Dinamo Samarqand'),
  ('Dominik Livaković', (SELECT id FROM public.teams WHERE code='CRO'), 'GK', 1, 'Dinamo Zagreb'),
  ('Josip Stanišić', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 2, 'Bayern Munich'),
  ('Marin Pongračić', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 3, 'Fiorentina'),
  ('Joško Gvardiol', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 4, 'Manchester City'),
  ('Duje Ćaleta-Car', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 5, 'Real Sociedad'),
  ('Josip Šutalo', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 6, 'Ajax'),
  ('Nikola Moro', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 7, 'Bologna'),
  ('Mateo Kovačić', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 8, 'Manchester City'),
  ('Andrej Kramarić', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 9, 'TSG Hoffenheim'),
  ('Luka Modrić (captain)', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 10, 'Milan'),
  ('Ante Budimir', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 11, 'Osasuna'),
  ('Ivor Pandur', (SELECT id FROM public.teams WHERE code='CRO'), 'GK', 12, 'Hull City'),
  ('Nikola Vlašić', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 13, 'Torino'),
  ('Ivan Perišić', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 14, 'PSV Eindhoven'),
  ('Mario Pašalić', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 15, 'Atalanta'),
  ('Martin Baturina', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 16, 'Como'),
  ('Petar Sučić', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 17, 'Inter Milan'),
  ('Kristijan Jakić', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 18, 'FC Augsburg'),
  ('Toni Fruk', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 19, 'Rijeka'),
  ('Igor Matanović', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 20, 'SC Freiburg'),
  ('Luka Sučić', (SELECT id FROM public.teams WHERE code='CRO'), 'MF', 21, 'Real Sociedad'),
  ('Luka Vušković', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 22, 'Hamburger SV'),
  ('Dominik Kotarski', (SELECT id FROM public.teams WHERE code='CRO'), 'GK', 23, 'Copenhagen'),
  ('Marco Pašalić', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 24, 'Orlando City SC'),
  ('Martin Erlić', (SELECT id FROM public.teams WHERE code='CRO'), 'DF', 25, 'Midtjylland'),
  ('Petar Musa', (SELECT id FROM public.teams WHERE code='CRO'), 'FW', 26, 'FC Dallas'),
  ('Jordan Pickford', (SELECT id FROM public.teams WHERE code='ENG'), 'GK', 1, 'Everton'),
  ('Ezri Konsa', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 2, 'Aston Villa'),
  ('Nico O''Reilly', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 3, 'Manchester City'),
  ('Declan Rice', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 4, 'Arsenal'),
  ('John Stones', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 5, 'Manchester City'),
  ('Marc Guéhi', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 6, 'Manchester City'),
  ('Bukayo Saka', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 7, 'Arsenal'),
  ('Elliot Anderson', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 8, 'Nottingham Forest'),
  ('Harry Kane (captain)', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 9, 'Bayern Munich'),
  ('Jude Bellingham', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 10, 'Real Madrid'),
  ('Marcus Rashford', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 11, 'Barcelona'),
  ('Tino Livramento', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 12, 'Newcastle United'),
  ('Dean Henderson', (SELECT id FROM public.teams WHERE code='ENG'), 'GK', 13, 'Crystal Palace'),
  ('Jordan Henderson', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 14, 'Brentford'),
  ('Dan Burn', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 15, 'Newcastle United'),
  ('Kobbie Mainoo', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 16, 'Manchester United'),
  ('Morgan Rogers', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 17, 'Aston Villa'),
  ('Anthony Gordon', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 18, 'Newcastle United'),
  ('Ollie Watkins', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 19, 'Aston Villa'),
  ('Noni Madueke', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 20, 'Arsenal'),
  ('Eberechi Eze', (SELECT id FROM public.teams WHERE code='ENG'), 'MF', 21, 'Arsenal'),
  ('Ivan Toney', (SELECT id FROM public.teams WHERE code='ENG'), 'FW', 22, 'Al-Ahli'),
  ('James Trafford', (SELECT id FROM public.teams WHERE code='ENG'), 'GK', 23, 'Manchester City'),
  ('Reece James', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 24, 'Chelsea'),
  ('Djed Spence', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 25, 'Tottenham Hotspur'),
  ('Jarell Quansah', (SELECT id FROM public.teams WHERE code='ENG'), 'DF', 26, 'Bayer Leverkusen'),
  ('Lawrence Ati-Zigi', (SELECT id FROM public.teams WHERE code='GHA'), 'GK', 1, 'St. Gallen'),
  ('Alidu Seidu', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 2, 'Rennes'),
  ('Caleb Yirenkyi', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 3, 'Nordsjælland'),
  ('Jonas Adjetey', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 4, 'VfL Wolfsburg'),
  ('Thomas Partey', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 5, 'Villarreal'),
  ('Abdul Mumin', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 6, 'Rayo Vallecano'),
  ('Abdul Fatawu', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 7, 'Leicester City'),
  ('Kwasi Sibo', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 8, 'Oviedo'),
  ('Jordan Ayew (captain)', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 9, 'Leicester City'),
  ('Brandon Thomas-Asante', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 10, 'Coventry City'),
  ('Antoine Semenyo', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 11, 'Manchester City'),
  ('Joseph Anang', (SELECT id FROM public.teams WHERE code='GHA'), 'GK', 12, 'St Patrick''s Athletic'),
  ('Christopher Bonsu Baah', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 13, 'Al-Qadsiah'),
  ('Gideon Mensah', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 14, 'Auxerre'),
  ('Elisha Owusu', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 15, 'Auxerre'),
  ('Benjamin Asare', (SELECT id FROM public.teams WHERE code='GHA'), 'GK', 16, 'Hearts of Oak'),
  ('Abdul Rahman Baba', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 17, 'PAOK'),
  ('Jerome Opoku', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 18, 'İstanbul Başakşehir'),
  ('Iñaki Williams', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 19, 'Athletic Bilbao'),
  ('Augustine Boakye', (SELECT id FROM public.teams WHERE code='GHA'), 'MF', 20, 'Saint-Étienne'),
  ('Kojo Peprah Oppong', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 21, 'Nice'),
  ('Kamaldeen Sulemana', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 22, 'Atalanta'),
  ('Derrick Luckassen', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 23, 'Pafos'),
  ('Ernest Nuamah', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 24, 'Lyon'),
  ('Prince Kwabena Adu', (SELECT id FROM public.teams WHERE code='GHA'), 'FW', 25, 'Viktoria Plzeň'),
  ('Marvin Senaya', (SELECT id FROM public.teams WHERE code='GHA'), 'DF', 26, 'Auxerre'),
  ('Luis Mejía', (SELECT id FROM public.teams WHERE code='PAN'), 'GK', 1, 'Nacional'),
  ('César Blackman', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 2, 'Slovan Bratislava'),
  ('José Córdoba', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 3, 'Norwich City'),
  ('Fidel Escobar', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 4, 'Saprissa'),
  ('Edgardo Fariña', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 5, 'Pari Nizhny Novgorod'),
  ('Cristian Martínez', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 6, 'Ironi Kiryat Shmona'),
  ('José Luis Rodríguez', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 7, 'Juárez'),
  ('Adalberto Carrasquilla', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 8, 'UNAM'),
  ('Tomás Rodríguez', (SELECT id FROM public.teams WHERE code='PAN'), 'FW', 9, 'Saprissa'),
  ('Ismael Díaz', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 10, 'León'),
  ('Yoel Bárcenas', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 11, 'Mazatlán'),
  ('César Samudio', (SELECT id FROM public.teams WHERE code='PAN'), 'GK', 12, 'Marathón'),
  ('Jiovany Ramos', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 13, 'Puerto Cabello'),
  ('Carlos Harvey', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 14, 'Minnesota United FC'),
  ('Eric Davis', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 15, 'Plaza Amador'),
  ('Andrés Andrade', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 16, 'LASK'),
  ('José Fajardo', (SELECT id FROM public.teams WHERE code='PAN'), 'FW', 17, 'Universidad Católica'),
  ('Cecilio Waterman', (SELECT id FROM public.teams WHERE code='PAN'), 'FW', 18, 'Universidad de Concepción'),
  ('Alberto Quintero', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 19, 'Plaza Amador'),
  ('Aníbal Godoy (captain)', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 20, 'San Diego FC'),
  ('César Yanis', (SELECT id FROM public.teams WHERE code='PAN'), 'MF', 21, 'Cobresal'),
  ('Orlando Mosquera', (SELECT id FROM public.teams WHERE code='PAN'), 'GK', 22, 'Al-Fayha'),
  ('Michael Amir Murillo', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 23, 'Beşiktaş'),
  ('Azarias Londoño', (SELECT id FROM public.teams WHERE code='PAN'), 'FW', 24, 'Universidad Católica'),
  ('Roderick Miller', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 25, 'Turan Tovuz'),
  ('Jorge Gutiérrez', (SELECT id FROM public.teams WHERE code='PAN'), 'DF', 26, 'Deportivo La Guaira');


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  018_group_pichichi.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 018_group_pichichi
-- Pronóstico del goleador (pichichi) de cada grupo. Acertar = 3 pts.
-- ============================================================================

-- Pronóstico del usuario: un jugador por grupo
CREATE TABLE IF NOT EXISTS group_top_scorer_predictions (
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  group_letter TEXT NOT NULL,
  player_id UUID REFERENCES players(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  PRIMARY KEY (user_id, group_letter)
);

ALTER TABLE group_top_scorer_predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own pichichi or after start readable" ON group_top_scorer_predictions;
DROP POLICY IF EXISTS "Insert own pichichi" ON group_top_scorer_predictions;
DROP POLICY IF EXISTS "Update own pichichi" ON group_top_scorer_predictions;

CREATE POLICY "Own pichichi or after start readable"
  ON group_top_scorer_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.tournament_started());

CREATE POLICY "Insert own pichichi"
  ON group_top_scorer_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own pichichi"
  ON group_top_scorer_predictions FOR UPDATE
  USING (auth.uid() = user_id);


-- Goleador real por grupo (lo carga el panel de resultados)
CREATE TABLE IF NOT EXISTS group_top_scorer (
  group_letter TEXT PRIMARY KEY,
  player_id UUID REFERENCES players(id) ON DELETE SET NULL,
  set_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

ALTER TABLE group_top_scorer ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Group scorer readable by authenticated" ON group_top_scorer;
DROP POLICY IF EXISTS "Group scorer insertable by authenticated" ON group_top_scorer;
DROP POLICY IF EXISTS "Group scorer updatable by authenticated" ON group_top_scorer;

CREATE POLICY "Group scorer readable by authenticated"
  ON group_top_scorer FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Group scorer insertable by authenticated"
  ON group_top_scorer FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Group scorer updatable by authenticated"
  ON group_top_scorer FOR UPDATE USING (auth.uid() IS NOT NULL);


-- Puntos por acertar el pichichi de un grupo (3 pts c/u)
CREATE OR REPLACE FUNCTION public.group_pichichi_points(p_user_id UUID)
RETURNS INT AS $$
  SELECT COALESCE(SUM(
    CASE WHEN gp.player_id IS NOT NULL AND gp.player_id = a.player_id THEN 3 ELSE 0 END
  ), 0)::INT
  FROM public.group_top_scorer_predictions gp
  JOIN public.group_top_scorer a ON a.group_letter = gp.group_letter
  WHERE gp.user_id = p_user_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- Ranking: total = partidos + macro + posiciones de grupo + pichichi de grupo
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
    (mp.total + public.macro_points(p.id) + public.group_position_points(p.id) + public.group_pichichi_points(p.id))::INT AS total_points,
    mp.total AS match_points,
    (public.macro_points(p.id) + public.group_position_points(p.id) + public.group_pichichi_points(p.id))::INT AS macro_points,
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


-- Desglose extra: macro + posiciones + pichichi
-- (la 013 la creó con menos columnas; hay que recrearla)
DROP FUNCTION IF EXISTS public.league_extra_breakdown(UUID);
CREATE OR REPLACE FUNCTION public.league_extra_breakdown(p_league_id UUID)
RETURNS TABLE (
  user_id UUID,
  macro_pts INT,
  group_pts INT,
  pichichi_pts INT
) AS $$
  SELECT
    lm.user_id,
    public.macro_points(lm.user_id),
    public.group_position_points(lm.user_id),
    public.group_pichichi_points(lm.user_id)
  FROM public.league_members lm
  WHERE lm.league_id = p_league_id
    AND public.is_league_member(p_league_id, auth.uid());
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  019_notifications.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 019_notifications
-- Marca de "última vez visto" por usuario, para derivar avisos (campana 🔔):
-- menciones de chat, resultados nuevos y nuevos miembros. Los partidos por
-- cerrar se derivan en vivo (sin marca).
-- ============================================================================

CREATE TABLE IF NOT EXISTS notification_seen (
  user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  chat_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
  results_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
  members_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch'
);

ALTER TABLE notification_seen ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own seen readable" ON notification_seen;
DROP POLICY IF EXISTS "Own seen insertable" ON notification_seen;
DROP POLICY IF EXISTS "Own seen updatable" ON notification_seen;

CREATE POLICY "Own seen readable"
  ON notification_seen FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Own seen insertable"
  ON notification_seen FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Own seen updatable"
  ON notification_seen FOR UPDATE USING (auth.uid() = user_id);


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>  020_push_subscriptions.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<

-- ============================================================================
-- PorrApp — 020_push_subscriptions
-- Suscripciones Web Push (VAPID) por dispositivo. Cada usuario gestiona las
-- suyas; el envío se hace desde el servidor con la service role.
-- ============================================================================

CREATE TABLE IF NOT EXISTS push_subscriptions (
  endpoint TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own subs readable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs insertable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs updatable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs deletable" ON push_subscriptions;

CREATE POLICY "Own subs readable"
  ON push_subscriptions FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Own subs insertable"
  ON push_subscriptions FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Own subs updatable"
  ON push_subscriptions FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Own subs deletable"
  ON push_subscriptions FOR DELETE USING (auth.uid() = user_id);

