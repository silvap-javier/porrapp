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
