"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/lib/types";

async function tournamentStarted(
  supabase: Awaited<ReturnType<typeof createClient>>
): Promise<boolean> {
  const { data } = await supabase.rpc("tournament_started");
  return data === true;
}

export async function saveMacroPicks(input: {
  championTeamId: string | null;
  runnerupTeamId: string | null;
  topScorer: string;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  // Los macro picks se cierran una vez arranca el torneo.
  if (await tournamentStarted(supabase)) {
    return { error: "tournament_started" };
  }

  const { error } = await supabase.from("macro_predictions").upsert(
    {
      user_id: user.id,
      champion_team_id: input.championTeamId || null,
      runnerup_team_id: input.runnerupTeamId || null,
      top_scorer: input.topScorer.trim() || null,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "user_id" }
  );

  if (error) return { error: "save_failed" };

  revalidatePath("/picks");
  return { ok: true };
}
