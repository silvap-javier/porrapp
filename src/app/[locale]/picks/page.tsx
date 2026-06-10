import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import MacroPicksForm from "@/components/MacroPicksForm";
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

  const { data: mine } = await supabase
    .from("macro_predictions")
    .select("champion_team_id, runnerup_team_id, top_scorer")
    .eq("user_id", user.id)
    .maybeSingle();

  const { data: started } = await supabase.rpc("tournament_started");

  return (
    <div className="max-w-md mx-auto px-4 py-8 space-y-6">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <p className="text-sm text-muted mt-1">{t("subtitle")}</p>
      </header>

      <MacroPicksForm
        teams={teams}
        initialChampion={mine?.champion_team_id ?? null}
        initialRunnerup={mine?.runnerup_team_id ?? null}
        initialTopScorer={mine?.top_scorer ?? null}
        locked={started === true}
      />
    </div>
  );
}
