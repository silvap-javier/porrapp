-- ============================================================================
-- PorrApp — 003_leagues
-- Ligas privadas entre amigos + miembros. Helpers SECURITY DEFINER para
-- evitar recursión en RLS (mismo patrón que FinanzApp).
-- ============================================================================


-- ============================================================================
-- Tablas (se crean ANTES que las funciones: los cuerpos SQL validan las
-- referencias a tablas al crearse, así que la tabla debe existir primero).
-- ============================================================================

CREATE TABLE IF NOT EXISTS leagues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  owner_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  join_code TEXT NOT NULL UNIQUE,
  scoring JSONB NOT NULL DEFAULT '{"exact": 3, "result": 1}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE TABLE IF NOT EXISTS league_members (
  league_id UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  joined_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  PRIMARY KEY (league_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_league_members_user ON league_members(user_id);
CREATE INDEX IF NOT EXISTS idx_league_members_league ON league_members(league_id);

ALTER TABLE leagues ENABLE ROW LEVEL SECURITY;
ALTER TABLE league_members ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- Helpers de membresía (SECURITY DEFINER para evitar recursión en RLS)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_league_member(p_league_id UUID, p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.league_members
    WHERE league_id = p_league_id AND user_id = p_user_id
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_league_owner(p_league_id UUID, p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.league_members
    WHERE league_id = p_league_id AND user_id = p_user_id AND role = 'owner'
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Resuelve una liga a partir de su código de invitación (bypassa RLS para que
-- un no-miembro pueda unirse conociendo el código).
CREATE OR REPLACE FUNCTION public.league_id_by_code(p_code TEXT)
RETURNS UUID AS $$
  SELECT id FROM public.leagues WHERE join_code = upper(trim(p_code));
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================================
-- Políticas: leagues
-- ============================================================================

DROP POLICY IF EXISTS "Leagues visible to members" ON leagues;
DROP POLICY IF EXISTS "Authenticated users can create leagues" ON leagues;
DROP POLICY IF EXISTS "League owners can update leagues" ON leagues;
DROP POLICY IF EXISTS "League owners can delete leagues" ON leagues;

CREATE POLICY "Leagues visible to members"
  ON leagues FOR SELECT
  USING (public.is_league_member(id, auth.uid()) OR auth.uid() = owner_id);

CREATE POLICY "Authenticated users can create leagues"
  ON leagues FOR INSERT
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "League owners can update leagues"
  ON leagues FOR UPDATE
  USING (public.is_league_owner(id, auth.uid()));

CREATE POLICY "League owners can delete leagues"
  ON leagues FOR DELETE
  USING (public.is_league_owner(id, auth.uid()));


-- ============================================================================
-- Políticas: league_members
-- ============================================================================

DROP POLICY IF EXISTS "Members visible to league members" ON league_members;
DROP POLICY IF EXISTS "Members can be added" ON league_members;
DROP POLICY IF EXISTS "Owners or self can remove members" ON league_members;

CREATE POLICY "Members visible to league members"
  ON league_members FOR SELECT
  USING (public.is_league_member(league_id, auth.uid()));

CREATE POLICY "Members can be added"
  ON league_members FOR INSERT
  WITH CHECK (
    -- Owner se añade a sí mismo al crear la liga
    (auth.uid() = user_id AND role = 'owner')
    OR
    -- Un usuario se une a sí mismo como member (vía código de invitación)
    (auth.uid() = user_id AND role = 'member')
    OR
    -- El owner añade a otros
    public.is_league_owner(league_id, auth.uid())
  );

CREATE POLICY "Owners or self can remove members"
  ON league_members FOR DELETE
  USING (
    public.is_league_owner(league_id, auth.uid())
    OR auth.uid() = user_id
  );
