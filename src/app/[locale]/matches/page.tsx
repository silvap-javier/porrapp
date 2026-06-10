import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import LaPorritaView, { type LMatch } from "@/components/LaPorritaView";
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

  const { data: teamsData } = await supabase
    .from("teams")
    .select("name, flag_emoji, group_letter")
    .order("name", { ascending: true });
  const teamsByGroup: Record<string, { flag: string; name: string }[]> = {};
  for (const tm of teamsData ?? []) {
    if (!tm.group_letter) continue;
    (teamsByGroup[tm.group_letter] ??= []).push({
      flag: tm.flag_emoji ?? "",
      name: tm.name,
    });
  }

  // Jornada por grupo: ordena los 6 partidos del grupo por match_number → pares.
  const idxInGroup: Record<string, number> = {};
  const matches: LMatch[] = rows.map((m) => {
    let jornada = 0;
    if (m.stage === "group" && m.group_letter) {
      const n = idxInGroup[m.group_letter] ?? 0;
      idxInGroup[m.group_letter] = n + 1;
      jornada = Math.floor(n / 2) + 1;
    }
    const pred = predByMatch.get(m.id);
    return {
      id: m.id,
      matchNumber: m.match_number,
      stage: m.stage,
      group: m.group_letter,
      jornada,
      kickoffAt: m.kickoff_at,
      status: m.status,
      homeScore: m.home_score,
      awayScore: m.away_score,
      home: sideLabel(m.home_team, m.home_slot),
      away: sideLabel(m.away_team, m.away_slot),
      predHome: pred?.home_score ?? null,
      predAway: pred?.away_score ?? null,
    };
  });

  return (
    <div className="max-w-2xl mx-auto px-3 py-6">
      <header className="mb-4 px-1">
        <h1 className="text-2xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-0.5">{t("subtitle")}</p>
      </header>

      <LaPorritaView matches={matches} teamsByGroup={teamsByGroup} />
    </div>
  );
}
