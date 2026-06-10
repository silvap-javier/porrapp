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
