-- ============================================================================
-- PorrApp — 015_players_extra
-- Amplía players con posición, dorsal y club (máxima info del scraper).
-- ============================================================================

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS position TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS shirt_number INT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS club TEXT;
