"use server";

import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { revalidatePath } from "next/cache";
import { sendPushToUsers } from "@/lib/push";
import type { ActionResult } from "@/lib/types";

/** Aviso push a todos los que están en alguna liga (menos quien lo cargó). */
async function notifyResult(matchId: string, setterId: string) {
  try {
    const admin = createAdminClient();
    const [{ data: match }, { data: members }] = await Promise.all([
      admin
        .from("matches")
        .select(
          `match_number, home_score, away_score, home_slot, away_slot,
           home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
           away_team:teams!matches_away_team_id_fkey(name, flag_emoji)`
        )
        .eq("id", matchId)
        .maybeSingle(),
      admin.from("league_members").select("user_id"),
    ]);
    const targets = Array.from(
      new Set((members ?? []).map((m) => m.user_id as string))
    ).filter((id) => id !== setterId);
    if (targets.length === 0) return;

    const m = match as unknown as {
      match_number: number;
      home_score: number | null;
      away_score: number | null;
      home_slot: string | null;
      away_slot: string | null;
      home_team: { name: string; flag_emoji: string | null } | null;
      away_team: { name: string; flag_emoji: string | null } | null;
    } | null;
    const home = m?.home_team
      ? `${m.home_team.flag_emoji ?? ""} ${m.home_team.name}`.trim()
      : m?.home_slot ?? "Local";
    const away = m?.away_team
      ? `${m.away_team.flag_emoji ?? ""} ${m.away_team.name}`.trim()
      : m?.away_slot ?? "Visitante";

    await sendPushToUsers(targets, {
      title: "✅ Nuevo resultado",
      body: `${home} ${m?.home_score ?? ""}-${m?.away_score ?? ""} ${away}`,
      url: "/dashboard",
      tag: `result-${matchId}`,
    });
  } catch {
    // best-effort
  }
}

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

  await notifyResult(input.matchId, user.id);

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

/** Goleador (pichichi) real de cada grupo, para puntuar los picks. */
export async function setGroupTopScorers(
  picks: { group: string; playerId: string | null }[]
): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const rows = picks
    .filter((p) => p.playerId)
    .map((p) => ({
      group_letter: p.group,
      player_id: p.playerId,
      set_by: user.id,
      updated_at: new Date().toISOString(),
    }));

  if (rows.length === 0) return { ok: true };

  const { error } = await supabase
    .from("group_top_scorer")
    .upsert(rows, { onConflict: "group_letter" });

  if (error) return { error: "save_failed" };

  revalidatePath("/results");
  revalidatePath("/dashboard");
  return { ok: true };
}
