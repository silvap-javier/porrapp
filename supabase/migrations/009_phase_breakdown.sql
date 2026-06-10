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
