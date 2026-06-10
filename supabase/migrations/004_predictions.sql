-- ============================================================================
-- PorrApp — 004_predictions
-- Pronósticos por partido + macro picks de torneo + resultado del torneo.
-- Los pronósticos son GLOBALES por usuario: se hacen una vez y valen en todas
-- las ligas en las que participa.
-- ============================================================================


-- ============================================================================
-- Helper: ¿ya empezó el torneo? (primer partido con kickoff pasado)
-- Bloquea los macro picks una vez arranca el Mundial.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.tournament_started()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.matches WHERE NOW() >= kickoff_at
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================================
-- Pronósticos de partido
-- ============================================================================

CREATE TABLE IF NOT EXISTS match_predictions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
  home_score INT NOT NULL CHECK (home_score >= 0),
  away_score INT NOT NULL CHECK (away_score >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  UNIQUE (user_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_match_predictions_user ON match_predictions(user_id);
CREATE INDEX IF NOT EXISTS idx_match_predictions_match ON match_predictions(match_id);


-- ============================================================================
-- Macro picks (campeón, subcampeón, goleador)
-- ============================================================================

CREATE TABLE IF NOT EXISTS macro_predictions (
  user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  champion_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  runnerup_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  top_scorer TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);


-- ============================================================================
-- Resultado real del torneo (fila única, la edita el panel de resultados)
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_outcome (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  champion_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  runnerup_team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
  top_scorer TEXT,
  set_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

INSERT INTO tournament_outcome (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- RLS
-- ============================================================================

ALTER TABLE match_predictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE macro_predictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournament_outcome ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own predictions or locked matches readable" ON match_predictions;
DROP POLICY IF EXISTS "Insert own predictions" ON match_predictions;
DROP POLICY IF EXISTS "Update own predictions" ON match_predictions;
DROP POLICY IF EXISTS "Delete own predictions" ON match_predictions;

-- Cada quien ve los suyos; los de otros sólo cuando el partido ya está
-- bloqueado (cerrado el plazo) — así nadie copia pronósticos antes de tiempo.
CREATE POLICY "Own predictions or locked matches readable"
  ON match_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.is_match_locked(match_id));

CREATE POLICY "Insert own predictions"
  ON match_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own predictions"
  ON match_predictions FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Delete own predictions"
  ON match_predictions FOR DELETE
  USING (auth.uid() = user_id);


DROP POLICY IF EXISTS "Own macro or after start readable" ON macro_predictions;
DROP POLICY IF EXISTS "Upsert own macro" ON macro_predictions;
DROP POLICY IF EXISTS "Update own macro" ON macro_predictions;

CREATE POLICY "Own macro or after start readable"
  ON macro_predictions FOR SELECT
  USING (auth.uid() = user_id OR public.tournament_started());

CREATE POLICY "Upsert own macro"
  ON macro_predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Update own macro"
  ON macro_predictions FOR UPDATE
  USING (auth.uid() = user_id);


DROP POLICY IF EXISTS "Outcome readable by authenticated" ON tournament_outcome;
DROP POLICY IF EXISTS "Outcome editable by authenticated" ON tournament_outcome;

CREATE POLICY "Outcome readable by authenticated"
  ON tournament_outcome FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Outcome editable by authenticated"
  ON tournament_outcome FOR UPDATE USING (auth.uid() IS NOT NULL);
