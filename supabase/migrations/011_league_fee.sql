-- ============================================================================
-- PorrApp — 011_league_fee
-- Cuota de entrada por liga (bote). Informativa: bote = cuota × nº miembros.
-- La edita el owner (la política UPDATE de leagues ya es owner-only).
-- ============================================================================

ALTER TABLE public.leagues
  ADD COLUMN IF NOT EXISTS entry_fee NUMERIC NOT NULL DEFAULT 0 CHECK (entry_fee >= 0);
