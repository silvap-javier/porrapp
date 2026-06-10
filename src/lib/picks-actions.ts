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

export async function saveGroupPositions(
  picks: { group: string; firstTeamId: string | null; secondTeamId: string | null }[]
): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  if (await tournamentStarted(supabase)) {
    return { error: "tournament_started" };
  }

  const rows = picks
    .filter((p) => p.firstTeamId || p.secondTeamId)
    .map((p) => ({
      user_id: user.id,
      group_letter: p.group,
      first_team_id: p.firstTeamId || null,
      second_team_id: p.secondTeamId || null,
      updated_at: new Date().toISOString(),
    }));

  if (rows.length === 0) return { ok: true };

  const { error } = await supabase
    .from("group_position_predictions")
    .upsert(rows, { onConflict: "user_id,group_letter" });

  if (error) return { error: "save_failed" };

  revalidatePath("/picks");
  return { ok: true };
}
