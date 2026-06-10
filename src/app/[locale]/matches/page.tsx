import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import MatchesView, { type ViewMatch } from "@/components/MatchesView";
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
};

export default async function MatchesPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("matches");

  const { data: matchesData } = await supabase
    .from("matches")
    .select(
      `id, match_number, stage, group_letter, kickoff_at, status, home_score, away_score, home_slot, away_slot, venue,
       home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
       away_team:teams!matches_away_team_id_fkey(name, flag_emoji)`
    )
    .order("match_number", { ascending: true });

  const rows = (matchesData ?? []) as unknown as MatchRow[];

  const { data: preds } = await supabase
    .from("match_predictions")
    .select("match_id, home_score, away_score")
    .eq("user_id", user.id);
  const predByMatch = new Map(
    (preds ?? []).map((p) => [p.match_id, p as { home_score: number; away_score: number }])
  );

  const matches: ViewMatch[] = rows.map((m) => {
    const pred = predByMatch.get(m.id);
    return {
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
      predHome: pred?.home_score ?? null,
      predAway: pred?.away_score ?? null,
    };
  });

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-6">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-1">{t("subtitle")}</p>
      </header>

      <MatchesView matches={matches} />
    </div>
  );
}
