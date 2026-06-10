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
