import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import OutcomeForm from "@/components/OutcomeForm";
import ResultsView, { type ViewResult } from "@/components/ResultsView";
import { sideLabel } from "@/lib/format";
import type { Stage, Team } from "@/lib/types";

type MatchRow = {
  id: string;
  match_number: number;
  stage: Stage;
  group_letter: string | null;
  kickoff_at: string;
  status: "scheduled" | "finished";
  home_score: number | null;
  away_score: number | null;
  home_slot: string | null;
  away_slot: string | null;
  venue: string | null;
  home_team: Pick<Team, "name" | "flag_emoji"> | null;
  away_team: Pick<Team, "name" | "flag_emoji"> | null;
  result_setter: { name: string | null } | null;
};

export default async function ResultsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("results");

  const { data: matchesData } = await supabase
    .from("matches")
    .select(
      `id, match_number, stage, group_letter, kickoff_at, status, home_score, away_score, home_slot, away_slot, venue,
       home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
       away_team:teams!matches_away_team_id_fkey(name, flag_emoji),
       result_setter:profiles!matches_result_set_by_fkey(name)`
    )
    .order("match_number", { ascending: true });

  const rows = (matchesData ?? []) as unknown as MatchRow[];
  const matches: ViewResult[] = rows.map((m) => ({
    id: m.id,
    stage: m.stage,
    group_letter: m.group_letter,
    kickoff_at: m.kickoff_at,
    status: m.status,
    home_score: m.home_score,
    away_score: m.away_score,
    home: sideLabel(m.home_team, m.home_slot),
    away: sideLabel(m.away_team, m.away_slot),
    venue: m.venue,
    setByName: m.result_setter?.name ?? null,
  }));

  const { data: teamsData } = await supabase
    .from("teams")
    .select("id, name, code, group_letter, flag_emoji")
    .order("name", { ascending: true });
  const teams = (teamsData ?? []) as Team[];

  const { data: outcome } = await supabase
    .from("tournament_outcome")
    .select("champion_team_id, runnerup_team_id, top_scorer")
    .eq("id", 1)
    .maybeSingle();

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-8">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-1">{t("subtitle")}</p>
      </header>

      <div className="bg-secondary/15 border border-secondary/40 text-foreground text-sm p-4 rounded-2xl">
        ⚠️ {t("sharedNotice")}
      </div>

      {/* Resultado del torneo (macro picks) */}
      <section className="bg-surface border border-border rounded-2xl p-5 shadow-[var(--shadow-warm)] space-y-3">
        <h2 className="font-semibold text-foreground">{t("tournamentOutcome")}</h2>
        <OutcomeForm
          teams={teams}
          initialChampion={outcome?.champion_team_id ?? null}
          initialRunnerup={outcome?.runnerup_team_id ?? null}
          initialTopScorer={outcome?.top_scorer ?? null}
        />
      </section>

      {/* Resultados de partidos */}
      <section className="space-y-3">
        <h2 className="font-semibold text-foreground">{t("matchResults")}</h2>
        <ResultsView matches={matches} />
      </section>
    </div>
  );
}
