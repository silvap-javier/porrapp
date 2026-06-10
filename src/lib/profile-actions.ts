"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/lib/types";

export async function updateProfileName(name: string): Promise<ActionResult> {
  const trimmed = name.trim();
  if (!trimmed) return { error: "name_required" };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase
    .from("profiles")
    .update({ name: trimmed, updated_at: new Date().toISOString() })
    .eq("id", user.id);

  if (error) return { error: "update_failed" };
  revalidatePath("/settings");
  return { ok: true };
}
