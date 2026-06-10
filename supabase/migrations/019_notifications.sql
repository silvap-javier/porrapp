-- ============================================================================
-- PorrApp — 019_notifications
-- Marca de "última vez visto" por usuario, para derivar avisos (campana 🔔):
-- menciones de chat, resultados nuevos y nuevos miembros. Los partidos por
-- cerrar se derivan en vivo (sin marca).
-- ============================================================================

CREATE TABLE IF NOT EXISTS notification_seen (
  user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  chat_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
  results_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
  members_seen_at TIMESTAMPTZ NOT NULL DEFAULT 'epoch'
);

ALTER TABLE notification_seen ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own seen readable" ON notification_seen;
DROP POLICY IF EXISTS "Own seen insertable" ON notification_seen;
DROP POLICY IF EXISTS "Own seen updatable" ON notification_seen;

CREATE POLICY "Own seen readable"
  ON notification_seen FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Own seen insertable"
  ON notification_seen FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Own seen updatable"
  ON notification_seen FOR UPDATE USING (auth.uid() = user_id);
