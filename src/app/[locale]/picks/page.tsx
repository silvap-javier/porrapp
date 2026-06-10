import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import MacroPicksForm from "@/components/MacroPicksForm";
import GroupPositionsForm from "@/components/GroupPositionsForm";
import GroupScorerForm from "@/components/GroupScorerForm";
import { buildGroupPlayers, type PlayerRow } from "@/lib/group-players";
import type { Team } from "@/lib/types";

export default async function PicksPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("picks");

  const { data: teamsData } = await supabase
    .from("teams")
    .select("id, name, code, group_letter, flag_emoji")
    .order("name", { ascending: true });
  const teams = (teamsData ?? []) as Team[];

  // Grupos con sus equipos
  const groupsMap: Record<string, Team[]> = {};
  for (const tm of teams) {
    if (!tm.group_letter) continue;
    (groupsMap[tm.group_letter] ??= []).push(tm);
  }
  const groups = Object.keys(groupsMap)
    .sort()
    .map((letter) => ({ letter, teams: groupsMap[letter] }));

  const { data: mine } = await supabase
    .from("macro_predictions")
    .select("champion_team_id, runnerup_team_id, top_scorer")
    .eq("user_id", user.id)
    .maybeSingle();

  const { data: groupPicks } = await supabase
    .from("group_position_predictions")
    .select("group_letter, first_team_id, second_team_id")
    .eq("user_id", user.id);
  const initialGroups: Record<string, { first: string | null; second: string | null }> = {};
  for (const gp of groupPicks ?? []) {
    initialGroups[gp.group_letter] = { first: gp.first_team_id, second: gp.second_team_id };
  }

  // Jugadores por grupo (para el pichichi) + picks del usuario
  const { data: playersData } = await supabase
    .from("players")
    .select("id, name, position, team:teams(name, group_letter, flag_emoji)")
    .order("name", { ascending: true });
  const groupPlayers = buildGroupPlayers((playersData ?? []) as unknown as PlayerRow[]);

  const { data: pichichiPicks } = await supabase
    .from("group_top_scorer_predictions")
    .select("group_letter, player_id")
    .eq("user_id", user.id);
  const initialPichichi: Record<string, string> = {};
  for (const r of pichichiPicks ?? []) if (r.player_id) initialPichichi[r.group_letter] = r.player_id;

  const { data: started } = await supabase.rpc("tournament_started");
  const locked = started === true;

  return (
    <div className="max-w-md mx-auto px-4 py-8 space-y-8">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-1">{t("subtitle")}</p>
      </header>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground">{t("tournamentSection")}</h2>
        <MacroPicksForm
          teams={teams}
          initialChampion={mine?.champion_team_id ?? null}
          initialRunnerup={mine?.runnerup_team_id ?? null}
          initialTopScorer={mine?.top_scorer ?? null}
          locked={locked}
        />
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground">{t("groupsSection")}</h2>
        <p className="text-sm text-muted">{t("groupsHint")}</p>
        <GroupPositionsForm groups={groups} initial={initialGroups} locked={locked} />
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground">{t("pichichiSection")}</h2>
        <p className="text-sm text-muted">{t("pichichiHint")}</p>
        <GroupScorerForm groups={groupPlayers} initial={initialPichichi} locked={locked} mode="pick" />
      </section>
    </div>
  );
}
