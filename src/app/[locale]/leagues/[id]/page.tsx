import { redirect, notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import LeagueActions from "@/components/LeagueActions";
import type { LeaderboardRow } from "@/lib/types";

export default async function LeaguePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("league");

  const { data: league } = await supabase
    .from("leagues")
    .select("id, name, owner_id, join_code")
    .eq("id", id)
    .maybeSingle();

  if (!league) notFound();

  const { data: board } = await supabase.rpc("league_leaderboard", {
    p_league_id: id,
  });
  const rows = (board ?? []) as LeaderboardRow[];
  const isOwner = league.owner_id === user.id;

  const medal = (i: number) => (i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : `${i + 1}.`);

  return (
    <div className="max-w-2xl mx-auto px-4 py-8 space-y-8">
      <header>
        <h1 className="text-3xl font-bold text-foreground font-display">🏆 {league.name}</h1>
        <p className="text-sm text-muted mt-1">
          {rows.length} {rows.length === 1 ? t("member") : t("members")}
        </p>
      </header>

      {/* Tabla */}
      <section className="bg-surface border border-border rounded-2xl shadow-[var(--shadow-warm)] overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-muted border-b border-border">
              <th className="text-left font-medium px-4 py-3 w-10">#</th>
              <th className="text-left font-medium px-2 py-3">{t("player")}</th>
              <th className="text-center font-medium px-2 py-3" title={t("exact")}>🎯</th>
              <th className="text-right font-medium px-4 py-3">{t("points")}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr
                key={r.user_id}
                className={`border-b border-border last:border-0 ${
                  r.user_id === user.id ? "bg-primary/5" : ""
                }`}
              >
                <td className="px-4 py-3 text-muted">{medal(i)}</td>
                <td className="px-2 py-3 font-medium text-foreground">
                  {r.name || r.email}
                  {r.user_id === user.id && (
                    <span className="text-xs text-primary ml-1">({t("you")})</span>
                  )}
                </td>
                <td className="px-2 py-3 text-center text-muted">{r.exact_count}</td>
                <td className="px-4 py-3 text-right font-bold text-foreground">{r.total_points}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {/* Invitación + acciones */}
      <section className="bg-surface border border-border rounded-2xl p-5 shadow-[var(--shadow-warm)]">
        <LeagueActions leagueId={league.id} joinCode={league.join_code} isOwner={isOwner} />
      </section>
    </div>
  );
}
