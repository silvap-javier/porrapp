"use server";

import { createClient } from "@/lib/supabase/server";

export type Notif = { type: "pending" | "mentions" | "results" | "members"; count: number };

export async function getNotifications(): Promise<{ items: Notif[]; total: number }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { items: [], total: 0 };

  const nowMs = new Date().getTime();
  const lockCut = new Date(nowMs + 60 * 60 * 1000).toISOString();
  const within48 = new Date(nowMs + 48 * 60 * 60 * 1000).toISOString();

  const [{ data: profile }, { data: seen }] = await Promise.all([
    supabase.from("profiles").select("name, email").eq("id", user.id).maybeSingle(),
    supabase
      .from("notification_seen")
      .select("chat_seen_at, results_seen_at, members_seen_at")
      .eq("user_id", user.id)
      .maybeSingle(),
  ]);

  const EPOCH = "1970-01-01T00:00:00Z";
  const chatSeen = seen?.chat_seen_at ?? EPOCH;
  const resultsSeen = seen?.results_seen_at ?? EPOCH;
  const membersSeen = seen?.members_seen_at ?? EPOCH;
  const myName = (profile?.name || "").trim();

  // a) Partidos por cerrar sin pronosticar (próx. 48 h)
  const { data: soon } = await supabase
    .from("matches")
    .select("id")
    .eq("status", "scheduled")
    .gt("kickoff_at", lockCut)
    .lte("kickoff_at", within48);
  const soonIds = (soon ?? []).map((m) => m.id);
  let pending = 0;
  if (soonIds.length) {
    const { data: preds } = await supabase
      .from("match_predictions")
      .select("match_id")
      .eq("user_id", user.id)
      .in("match_id", soonIds);
    const predSet = new Set((preds ?? []).map((p) => p.match_id));
    pending = soonIds.filter((id) => !predSet.has(id)).length;
  }

  // b) Menciones nuevas en chats de mis ligas
  let mentions = 0;
  if (myName) {
    const { count } = await supabase
      .from("league_messages")
      .select("*", { count: "exact", head: true })
      .gt("created_at", chatSeen)
      .neq("user_id", user.id)
      .ilike("body", `%@${myName}%`);
    mentions = count ?? 0;
  }

  // c) Resultados cargados desde la última visita
  const { count: resultsCount } = await supabase
    .from("matches")
    .select("*", { count: "exact", head: true })
    .eq("status", "finished")
    .gt("result_set_at", resultsSeen);
  const results = resultsCount ?? 0;

  // d) Nuevos miembros en ligas que soy owner
  const { data: ownedLeagues } = await supabase
    .from("leagues")
    .select("id")
    .eq("owner_id", user.id);
  const ownedIds = (ownedLeagues ?? []).map((l) => l.id);
  let members = 0;
  if (ownedIds.length) {
    const { count } = await supabase
      .from("league_members")
      .select("*", { count: "exact", head: true })
      .in("league_id", ownedIds)
      .neq("user_id", user.id)
      .gt("joined_at", membersSeen);
    members = count ?? 0;
  }

  const items: Notif[] = [
    { type: "pending", count: pending },
    { type: "mentions", count: mentions },
    { type: "results", count: results },
    { type: "members", count: members },
  ].filter((i) => i.count > 0) as Notif[];

  return { items, total: items.reduce((n, i) => n + i.count, 0) };
}

/** Marca como vistos los avisos basados en marca temporal (no los partidos por cerrar). */
export async function markNotificationsSeen(): Promise<{ ok: true } | { error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const now = new Date().toISOString();
  const { error } = await supabase.from("notification_seen").upsert(
    { user_id: user.id, chat_seen_at: now, results_seen_at: now, members_seen_at: now },
    { onConflict: "user_id" }
  );
  if (error) return { error: "save_failed" };
  return { ok: true };
}
