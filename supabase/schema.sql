-- ============================================================================
-- PorrApp — schema completo (001→014). Pegar en el SQL Editor de Supabase.
-- Idempotente: re-ejecutable.
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
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  group_letter TEXT NOT NULL,
  first_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  second_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  PRIMARY KEY (user_id, group_letter)
);

ALTER TABLE group_position_predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own group picks or after start readable" ON group_position_predictions;
DROP POLICY IF EXISTS "Insert own group picks" ON group_position_predictions;
DROP POLICY IF EXISTS "Update own group picks" ON group_position_predictions;

CREATE POLICY "Own group picks or after start readable"
  ON group_position_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.tournament_started());

CREATE POLICY "Insert own group picks"
  ON group_position_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own group picks"
  ON group_position_predictions FOR UPDATE
  USING (auth.uid() = user_id);


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

