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

export type RivalPrediction = {
  userId: string;
  name: string;
  home: number;
  away: number;
};

/**
 * Pronósticos de tus compañeros de liga para un partido YA CERRADO.
 * La RLS solo deja leer pronósticos ajenos una vez bloqueado el partido;
 * además aquí lo acotamos a gente con la que compartes alguna liga.
 */
export async function getMatchPredictions(matchId: string): Promise<RivalPrediction[]> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return [];

  // Solo si el partido ya está cerrado (no filtramos pronósticos abiertos).
  const { data: match } = await supabase
    .from("matches")
    .select("kickoff_at, status")
    .eq("id", matchId)
    .maybeSingle();
  if (!match || isMatchOpen(match.kickoff_at, match.status)) return [];

  // Mis ligas → compañeros (incluyéndome).
  const { data: myLeagues } = await supabase
    .from("league_members")
    .select("league_id")
    .eq("user_id", user.id);
  const leagueIds = (myLeagues ?? []).map((l) => l.league_id);
  if (leagueIds.length === 0) return [];

  const { data: mates } = await supabase
    .from("league_members")
    .select("user_id")
    .in("league_id", leagueIds);
  const mateIds = Array.from(new Set((mates ?? []).map((m) => m.user_id)));
  if (mateIds.length === 0) return [];

  const { data: preds } = await supabase
    .from("match_predictions")
    .select("user_id, home_score, away_score, profiles(name)")
    .eq("match_id", matchId)
    .in("user_id", mateIds);

  return ((preds ?? []) as unknown as {
    user_id: string;
    home_score: number;
    away_score: number;
    profiles: { name: string | null } | null;
  }[]).map((p) => ({
    userId: p.user_id,
    name: p.profiles?.name?.trim() || "Jugador",
    home: p.home_score,
    away: p.away_score,
  }));
}
