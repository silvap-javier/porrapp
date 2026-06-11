"use server";

import { createClient } from "@/lib/supabase/server";
import type { ActionResult } from "@/lib/types";

export async function savePushSubscription(sub: {
  endpoint: string;
  p256dh: string;
  auth: string;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase.from("push_subscriptions").upsert(
    { endpoint: sub.endpoint, user_id: user.id, p256dh: sub.p256dh, auth: sub.auth },
    { onConflict: "endpoint" }
  );
  if (error) return { error: "save_failed" };
  return { ok: true };
}

export async function deletePushSubscription(endpoint: string): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  await supabase.from("push_subscriptions").delete().eq("endpoint", endpoint);
  return { ok: true };
}
