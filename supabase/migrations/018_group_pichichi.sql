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
