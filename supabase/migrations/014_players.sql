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
