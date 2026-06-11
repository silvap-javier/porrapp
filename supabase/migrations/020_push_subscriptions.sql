-- ============================================================================
-- PorrApp — 020_push_subscriptions
-- Suscripciones Web Push (VAPID) por dispositivo. Cada usuario gestiona las
-- suyas; el envío se hace desde el servidor con la service role.
-- ============================================================================

CREATE TABLE IF NOT EXISTS push_subscriptions (
  endpoint TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own subs readable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs insertable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs updatable" ON push_subscriptions;
DROP POLICY IF EXISTS "Own subs deletable" ON push_subscriptions;

CREATE POLICY "Own subs readable"
  ON push_subscriptions FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Own subs insertable"
  ON push_subscriptions FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Own subs updatable"
  ON push_subscriptions FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Own subs deletable"
  ON push_subscriptions FOR DELETE USING (auth.uid() = user_id);
