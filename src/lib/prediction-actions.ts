"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/lib/types";
import { isMatchOpen } from "@/lib/scoring";

export async function savePrediction(input: {
  matchId: string;
  homeScore: number;
  awayScore: number;
}): Promise<ActionResult> {
  const { matchId } = input;
  const homeScore = Math.trunc(Number(input.homeScore));
  const awayScore = Math.trunc(Number(input.awayScore));

  if (!Number.isFinite(homeScore) || !Number.isFinite(awayScore)) {
    return { error: "invalid_score" };
  }
  if (homeScore < 0 || awayScore < 0 || homeScore > 99 || awayScore > 99) {
    return { error: "invalid_score" };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  // El bloqueo se valida en servidor además de en RLS/UI.
  const { data: match, error: matchErr } = await supabase
    .from("matches")
    .select("kickoff_at, status")
    .eq("id", matchId)
    .maybeSingle();
  if (matchErr || !match) return { error: "match_not_found" };
  if (!isMatchOpen(match.kickoff_at, match.status)) {
    return { error: "match_locked" };
  }

  const { error } = await supabase.from("match_predictions").upsert(
    {
      user_id: user.id,
      match_id: matchId,
      home_score: homeScore,
      away_score: awayScore,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "user_id,match_id" }
  );

  if (error) return { error: "save_failed" };

  revalidatePath("/matches");
  revalidatePath("/dashboard");
  return { ok: true };
}
