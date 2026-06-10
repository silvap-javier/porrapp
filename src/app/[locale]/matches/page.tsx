import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import MatchCard from "@/components/MatchCard";
import { sideLabel } from "@/lib/format";
import { STAGE_LABELS, type Stage, type Team } from "@/lib/types";

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
  home_team: Pick<Team, "name" | "flag_emoji"> | null;
  away_team: Pick<Team, "name" | "flag_emoji"> | null;
};

const STAGE_ORDER: Stage[] = ["group", "r32", "r16", "qf", "sf", "third", "final"];

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
      `id, match_number, stage, group_letter, kickoff_at, status, home_score, away_score, home_slot, away_slot,
       home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
       away_team:teams!matches_away_team_id_fkey(name, flag_emoji)`
    )
    .order("match_number", { ascending: true });

  const matches = (matchesData ?? []) as unknown as MatchRow[];

  const { data: preds } = await supabase
    .from("match_predictions")
    .select("match_id, home_score, away_score")
    .eq("user_id", user.id);
  const predByMatch = new Map(
    (preds ?? []).map((p) => [p.match_id, p as { home_score: number; away_score: number }])
  );

  // Agrupa por fase
  const byStage = new Map<Stage, MatchRow[]>();
  for (const m of matches) {
    const arr = byStage.get(m.stage) ?? [];
    arr.push(m);
    byStage.set(m.stage, arr);
  }

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-8">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-1">{t("subtitle")}</p>
      </header>

      {STAGE_ORDER.filter((s) => byStage.has(s)).map((stage) => (
        <section key={stage} className="space-y-3">
          <h2 className="text-lg font-semibold text-foreground sticky top-14 bg-background/80 backdrop-blur py-1 z-10">
            {STAGE_LABELS[stage]}
          </h2>
          <div className="space-y-3">
            {byStage.get(stage)!.map((m) => {
              const home = sideLabel(m.home_team, m.home_slot);
              const away = sideLabel(m.away_team, m.away_slot);
              const pred = predByMatch.get(m.id);
              return (
                <div key={m.id}>
                  {m.group_letter && (
                    <span className="text-xs text-muted ml-1">{t("group")} {m.group_letter}</span>
                  )}
                  <MatchCard
                    matchId={m.id}
                    home={home}
                    away={away}
                    kickoffAt={m.kickoff_at}
                    status={m.status}
                    homeScore={m.home_score}
                    awayScore={m.away_score}
                    initialHome={pred?.home_score ?? null}
                    initialAway={pred?.away_score ?? null}
                  />
                </div>
              );
            })}
          </div>
        </section>
      ))}
    </div>
  );
}
