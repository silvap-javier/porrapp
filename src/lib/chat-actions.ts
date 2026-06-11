"use server";

import { createClient } from "@/lib/supabase/server";
import { sendPushToUsers } from "@/lib/push";
import type { ActionResult } from "@/lib/types";

export type ChatMessage = {
  id: string;
  user_id: string;
  body: string;
  created_at: string;
};

export async function sendMessage(
  leagueId: string,
  body: string
): Promise<ActionResult<{ message: ChatMessage }>> {
  const trimmed = body.trim();
  if (!trimmed) return { error: "empty_message" };
  if (trimmed.length > 2000) return { error: "message_too_long" };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { data, error } = await supabase
    .from("league_messages")
    .insert({ league_id: leagueId, user_id: user.id, body: trimmed })
    .select("id, user_id, body, created_at")
    .single();

  if (error || !data) return { error: "save_failed" };

  // Push a los mencionados (@Nombre) de la liga, salvo el autor. Best-effort.
  try {
    const lower = trimmed.toLowerCase();
    if (lower.includes("@")) {
      const [{ data: members }, { data: league }, { data: me }] = await Promise.all([
        supabase
          .from("league_members")
          .select("user_id, profiles(name)")
          .eq("league_id", leagueId),
        supabase.from("leagues").select("name").eq("id", leagueId).maybeSingle(),
        supabase.from("profiles").select("name").eq("id", user.id).maybeSingle(),
      ]);
      const rows = (members ?? []) as unknown as {
        user_id: string;
        profiles: { name: string | null } | null;
      }[];
      const targets = rows
        .filter((m) => m.user_id !== user.id)
        .filter((m) => {
          const n = (m.profiles?.name ?? "").trim().toLowerCase();
          return n.length > 0 && lower.includes(`@${n}`);
        })
        .map((m) => m.user_id);
      if (targets.length) {
        const who = (me?.name || "Alguien").trim();
        await sendPushToUsers(targets, {
          title: `💬 ${league?.name ?? "Tu liga"}`,
          body: `${who} te mencionó: ${trimmed.slice(0, 120)}`,
          url: "/dashboard",
          tag: `chat-${leagueId}`,
        });
      }
    }
  } catch {
    // el chat no debe fallar por un problema de push
  }

  return { ok: true, message: data as ChatMessage };
}
