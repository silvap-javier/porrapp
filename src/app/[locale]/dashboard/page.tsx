import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { createClient } from "@/lib/supabase/server";
import JoinLeagueForm from "@/components/JoinLeagueForm";
import MatchCard from "@/components/MatchCard";
import { sideLabel } from "@/lib/format";
import type { Team } from "@/lib/types";

type MatchRow = {
  id: string;
  match_number: number;
  kickoff_at: string;
  status: "scheduled" | "finished";
  home_score: number | null;
  away_score: number | null;
  home_slot: string | null;
  away_slot: string | null;
  venue: string | null;
  home_team: Pick<Team, "name" | "flag_emoji"> | null;
  away_team: Pick<Team, "name" | "flag_emoji"> | null;
};

export default async function DashboardPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("dashboard");

  // Ligas del usuario
  const { data: memberships } = await supabase
    .from("league_members")
    .select("role, leagues(id, name, join_code)")
    .eq("user_id", user.id);

  const leagues = (memberships ?? [])
    .map((m) => {
      const lg = m.leagues as unknown as { id: string; name: string; join_code: string } | null;
      return lg ? { ...lg, role: m.role as string } : null;
    })
    .filter(Boolean) as { id: string; name: string; join_code: string; role: string }[];

  // Puntos totales del usuario
  const { data: mp } = await supabase.rpc("match_points", { p_user_id: user.id });
  const { data: macro } = await supabase.rpc("macro_points", { p_user_id: user.id });
  const matchStats = Array.isArray(mp) && mp[0] ? mp[0] : { total: 0, exact_count: 0, predicted_count: 0 };
  const totalPoints = (matchStats.total ?? 0) + (macro ?? 0);

  // Próximos partidos
  const nowIso = new Date().toISOString();
  const { data: upcoming } = await supabase
    .from("matches")
    .select(
      `id, match_number, kickoff_at, status, home_score, away_score, home_slot, away_slot, venue,
       home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
       away_team:teams!matches_away_team_id_fkey(name, flag_emoji)`
    )
    .gte("kickoff_at", nowIso)
    .eq("status", "scheduled")
    .order("kickoff_at", { ascending: true })
    .limit(5);

  const upcomingMatches = (upcoming ?? []) as unknown as MatchRow[];
  const matchIds = upcomingMatches.map((m) => m.id);
  const { data: preds } = matchIds.length
    ? await supabase
        .from("match_predictions")
        .select("match_id, home_score, away_score")
        .eq("user_id", user.id)
        .in("match_id", matchIds)
    : { data: [] };
  const predByMatch = new Map(
    (preds ?? []).map((p) => [p.match_id, p as { home_score: number; away_score: number }])
  );

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-10">
      <header className="flex items-center justify-between gap-4">
        <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>
        <div className="text-right">
          <div className="text-3xl font-bold text-primary">{totalPoints}</div>
          <div className="text-xs text-muted">{t("yourPoints")}</div>
        </div>
      </header>

      {/* Ligas */}
      <section className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-foreground">{t("yourLeagues")}</h2>
          <Link
            href="/leagues/new"
            className="text-sm bg-primary text-white px-4 py-2 rounded-full font-medium hover:bg-primary-dark transition-colors"
          >
            {t("newLeague")}
          </Link>
        </div>

        {leagues.length === 0 ? (
          <p className="text-sm text-muted bg-surface border border-border rounded-2xl p-5">
            {t("noLeagues")}
          </p>
        ) : (
          <ul className="space-y-2">
            {leagues.map((lg) => (
              <li key={lg.id}>
                <Link
                  href={`/leagues/${lg.id}`}
                  className="flex items-center justify-between bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)] hover:border-primary/40 transition-colors"
                >
                  <span className="font-medium text-foreground">🏆 {lg.name}</span>
                  <span className="text-xs font-mono text-muted">{lg.join_code}</span>
                </Link>
              </li>
            ))}
          </ul>
        )}

        <div className="bg-surface border border-border rounded-2xl p-4">
          <p className="text-sm font-medium text-foreground mb-2">{t("joinLeague")}</p>
          <JoinLeagueForm />
        </div>
      </section>

      {/* Próximos partidos */}
      <section className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-foreground">{t("upcoming")}</h2>
          <Link href="/matches" className="text-sm text-primary hover:text-primary-dark">
            {t("allMatches")} →
          </Link>
        </div>

        {upcomingMatches.length === 0 ? (
          <p className="text-sm text-muted">{t("noUpcoming")}</p>
        ) : (
          <div className="space-y-3">
            {upcomingMatches.map((m) => {
              const home = sideLabel(m.home_team, m.home_slot);
              const away = sideLabel(m.away_team, m.away_slot);
              const pred = predByMatch.get(m.id);
              return (
                <MatchCard
                  key={m.id}
                  matchId={m.id}
                  home={home}
                  away={away}
                  kickoffAt={m.kickoff_at}
                  status={m.status}
                  homeScore={m.home_score}
                  awayScore={m.away_score}
                  initialHome={pred?.home_score ?? null}
                  initialAway={pred?.away_score ?? null}
                  venue={m.venue}
                />
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
