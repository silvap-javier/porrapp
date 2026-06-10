"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/lib/types";

// Sin caracteres ambiguos (0/O, 1/I) para que el código se dicte fácil.
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateCode(len = 6): string {
  let code = "";
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  for (let i = 0; i < len; i++) {
    code += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return code;
}

export async function createLeague(
  name: string
): Promise<ActionResult<{ leagueId: string }>> {
  const trimmed = name.trim();
  if (!trimmed) return { error: "name_required" };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  // Reintenta ante una colisión de código (muy improbable).
  let leagueId: string | null = null;
  for (let attempt = 0; attempt < 5 && !leagueId; attempt++) {
    const { data, error } = await supabase
      .from("leagues")
      .insert({ name: trimmed, owner_id: user.id, join_code: generateCode() })
      .select("id")
      .single();

    if (data) {
      leagueId = data.id;
    } else if (error && error.code !== "23505") {
      return { error: "create_failed" };
    }
  }

  if (!leagueId) return { error: "create_failed" };

  const { error: memberErr } = await supabase
    .from("league_members")
    .insert({ league_id: leagueId, user_id: user.id, role: "owner" });

  if (memberErr) return { error: "create_failed" };

  revalidatePath("/dashboard");
  return { ok: true, leagueId };
}

export async function joinLeague(
  code: string
): Promise<ActionResult<{ leagueId: string }>> {
  const clean = code.trim().toUpperCase();
  if (!clean) return { error: "code_required" };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  // Resuelve la liga por código vía función SECURITY DEFINER (bypassa RLS).
  const { data: leagueId, error: rpcErr } = await supabase.rpc(
    "league_id_by_code",
    { p_code: clean }
  );
  if (rpcErr) return { error: "join_failed" };
  if (!leagueId) return { error: "league_not_found" };

  const { error: insertErr } = await supabase
    .from("league_members")
    .insert({ league_id: leagueId, user_id: user.id, role: "member" });

  if (insertErr) {
    if (insertErr.code === "23505") return { error: "already_member" };
    return { error: "join_failed" };
  }

  revalidatePath("/dashboard");
  return { ok: true, leagueId };
}

export async function leaveLeague(leagueId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { data: members, error: fetchErr } = await supabase
    .from("league_members")
    .select("user_id, role")
    .eq("league_id", leagueId);
  if (fetchErr) return { error: "fetch_failed" };

  const me = members?.find((m) => m.user_id === user.id);
  if (!me) return { error: "not_member" };
  if (me.role === "owner" && (members?.length ?? 0) > 1) {
    return { error: "owner_cant_leave_with_members" };
  }

  const { error } = await supabase
    .from("league_members")
    .delete()
    .eq("league_id", leagueId)
    .eq("user_id", user.id);
  if (error) return { error: "leave_failed" };

  revalidatePath("/dashboard");
  return { ok: true };
}

export async function deleteLeague(leagueId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase.from("leagues").delete().eq("id", leagueId);
  if (error) return { error: "delete_failed" };

  revalidatePath("/dashboard");
  return { ok: true };
}

export async function removeMember(
  leagueId: string,
  userId: string
): Promise<ActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "not_authenticated" };

  const { error } = await supabase
    .from("league_members")
    .delete()
    .eq("league_id", leagueId)
    .eq("user_id", userId);
  if (error) return { error: "remove_failed" };

  revalidatePath(`/leagues/${leagueId}`);
  return { ok: true };
}
