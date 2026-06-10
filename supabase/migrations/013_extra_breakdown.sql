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
