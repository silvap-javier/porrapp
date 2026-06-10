"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/lib/types";

/**
 * Carga o corrige el resultado de un partido. Lo puede hacer CUALQUIER usuario
 * autenticado (fuente de verdad compartida) y cada cambio queda en
 * match_result_log con quién y cuándo, para mantener la transparencia.
 */
export async function setMatchResult(input: {
  matchId: string;
  homeScore: number;
  awayScore: number;
}): Promise<ActionResult> {
  const homeScore = Math.trunc(Number(input.homeScore));
  const awayScore = Math.trunc(Number(input.awayScore));

  if (
    !Number.isFinite(homeScore) ||
    !Number.isFinite(awayScore) ||
    homeScore < 0 ||
    awayScore < 0 ||
    homeScore > 99 ||
    awayScore > 99
  ) {
    return { error: "invalid_score" };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const now = new Date().toISOString();
  const { error } = await supabase
    .from("matches")
    .update({
      home_score: homeScore,
      away_score: awayScore,
      status: "finished",
      result_set_by: user.id,
      result_set_at: now,
    })
    .eq("id", input.matchId);

  if (error) return { error: "save_failed" };

  await supabase.from("match_result_log").insert({
    match_id: input.matchId,
    set_by: user.id,
    home_score: homeScore,
    away_score: awayScore,
  });

  revalidatePath("/results");
  revalidatePath("/matches");
  revalidatePath("/dashboard");
  return { ok: true };
}

/** Reabre un partido (borra el resultado) — útil si se cargó por error. */
export async function clearMatchResult(matchId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase
    .from("matches")
    .update({
      home_score: null,
      away_score: null,
      status: "scheduled",
      result_set_by: user.id,
      result_set_at: new Date().toISOString(),
    })
    .eq("id", matchId);

  if (error) return { error: "save_failed" };

  revalidatePath("/results");
  revalidatePath("/matches");
  revalidatePath("/dashboard");
  return { ok: true };
}

/** Asigna los equipos de un cruce de eliminatorias (cuando se definen). */
export async function setKnockoutTeams(input: {
  matchId: string;
  homeTeamId: string | null;
  awayTeamId: string | null;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase
    .from("matches")
    .update({
      home_team_id: input.homeTeamId || null,
      away_team_id: input.awayTeamId || null,
    })
    .eq("id", input.matchId);

  if (error) return { error: "save_failed" };

  revalidatePath("/results");
  revalidatePath("/matches");
  return { ok: true };
}

/** Resultado del torneo para puntuar los macro picks. */
export async function setTournamentOutcome(input: {
  championTeamId: string | null;
  runnerupTeamId: string | null;
  topScorer: string;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase
    .from("tournament_outcome")
    .update({
      champion_team_id: input.championTeamId || null,
      runnerup_team_id: input.runnerupTeamId || null,
      top_scorer: input.topScorer.trim() || null,
      set_by: user.id,
      updated_at: new Date().toISOString(),
    })
    .eq("id", 1);

  if (error) return { error: "save_failed" };

  revalidatePath("/results");
  revalidatePath("/dashboard");
  return { ok: true };
}
