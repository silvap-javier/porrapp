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
