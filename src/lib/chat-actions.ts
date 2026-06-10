"use server";

import { createClient } from "@/lib/supabase/server";
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
  return { ok: true, message: data as ChatMessage };
}
