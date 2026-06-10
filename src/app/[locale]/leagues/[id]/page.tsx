import { redirect, notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import LeagueHub from "@/components/LeagueHub";
import { sideLabel } from "@/lib/format";
import type { LeaderboardRow, Stage, Team } from "@/lib/types";
import type { LMatch } from "@/components/LaPorritaView";
import type { GroupStanding, PhaseRow } from "@/components/LeagueHub";
import type { ChatMessage } from "@/lib/chat-actions";

type MatchRow = {
  id: string;
  match_number: number;
  stage: Stage;
  group_letter: string | null;
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

  const { data: league } = await supabase
    .from("leagues")
    .select("id, name, owner_id, join_code")
    .eq("id", id)
    .maybeSingle();
  if (!league) notFound();

  const [{ data: board }, { data: breakdown }, { data: members }, { data: matchesData }, { data: preds }, { data: teamsData }, { data: msgs }] =
    await Promise.all([
      supabase.rpc("league_leaderboard", { p_league_id: id }),
      supabase.rpc("league_phase_breakdown", { p_league_id: id }),
      supabase.from("league_members").select("user_id").eq("league_id", id),
      supabase
        .from("matches")
        .select(
          `id, match_number, stage, group_letter, kickoff_at, status, home_score, away_score, home_slot, away_slot, venue,
           home_team:teams!matches_home_team_id_fkey(name, flag_emoji),
           away_team:teams!matches_away_team_id_fkey(name, flag_emoji)`
        )
        .order("match_number", { ascending: true }),
      supabase.from("match_predictions").select("match_id, home_score, away_score").eq("user_id", user.id),
      supabase.from("teams").select("name, flag_emoji, group_letter").order("name", { ascending: true }),
      supabase
        .from("league_messages")
        .select("id, user_id, body, created_at")
        .eq("league_id", id)
        .order("created_at", { ascending: true })
        .limit(50),
    ]);

  const rows = (matchesData ?? []) as unknown as MatchRow[];
  const predByMatch = new Map(
    (preds ?? []).map((p) => [p.match_id, p as { home_score: number; away_score: number }])
  );

  // Equipos por grupo
  const teamsByGroup: Record<string, { flag: string; name: string }[]> = {};
  for (const tm of teamsData ?? []) {
    if (!tm.group_letter) continue;
    (teamsByGroup[tm.group_letter] ??= []).push({ flag: tm.flag_emoji ?? "", name: tm.name });
  }

  // LMatch[] con jornada
  const idxInGroup: Record<string, number> = {};
  const matches: LMatch[] = rows.map((m) => {
    let jornada = 0;
    if (m.stage === "group" && m.group_letter) {
      const n = idxInGroup[m.group_letter] ?? 0;
      idxInGroup[m.group_letter] = n + 1;
      jornada = Math.floor(n / 2) + 1;
    }
    const pred = predByMatch.get(m.id);
    return {
      id: m.id,
      matchNumber: m.match_number,
      stage: m.stage,
      group: m.group_letter,
      jornada,
      kickoffAt: m.kickoff_at,
      status: m.status,
      homeScore: m.home_score,
      awayScore: m.away_score,
      home: sideLabel(m.home_team, m.home_slot),
      away: sideLabel(m.away_team, m.away_slot),
      predHome: pred?.home_score ?? null,
      predAway: pred?.away_score ?? null,
    };
  });

  // Clasificación por grupo (desde partidos finalizados)
  const standings: GroupStanding[] = [];
  const groups = Array.from(new Set(rows.filter((m) => m.group_letter).map((m) => m.group_letter as string))).sort();
  for (const g of groups) {
    const init = (teamsByGroup[g] ?? []).map((tm) => ({
      ...tm, pj: 0, g: 0, e: 0, p: 0, gf: 0, gc: 0, dg: 0, pts: 0,
    }));
    const byName = new Map(init.map((r) => [r.name, r]));
    for (const m of rows) {
      if (m.group_letter !== g || m.status !== "finished" || m.home_score === null || m.away_score === null) continue;
      const hn = m.home_team?.name, an = m.away_team?.name;
      const H = hn ? byName.get(hn) : null;
      const A = an ? byName.get(an) : null;
      if (!H || !A) continue;
      H.pj++; A.pj++;
      H.gf += m.home_score; H.gc += m.away_score;
      A.gf += m.away_score; A.gc += m.home_score;
      if (m.home_score > m.away_score) { H.g++; H.pts += 3; A.p++; }
      else if (m.home_score < m.away_score) { A.g++; A.pts += 3; H.p++; }
      else { H.e++; A.e++; H.pts++; A.pts++; }
    }
    init.forEach((r) => (r.dg = r.gf - r.gc));
    init.sort((x, y) => y.pts - x.pts || y.dg - x.dg || y.gf - x.gf || x.name.localeCompare(y.name));
    standings.push({ group: g, rows: init });
  }

  // Máximo de puntos por fase (nº partidos × 4)
  const maxByStage: Record<string, number> = {};
  for (const m of rows) maxByStage[m.stage] = (maxByStage[m.stage] ?? 0) + 4;

  return (
    <LeagueHub
      league={{
        id: league.id,
        name: league.name,
        joinCode: league.join_code,
        isOwner: league.owner_id === user.id,
        memberCount: members?.length ?? 0,
      }}
      currentUserId={user.id}
      leaderboard={(board ?? []) as LeaderboardRow[]}
      breakdown={(breakdown ?? []) as PhaseRow[]}
      maxByStage={maxByStage}
      matches={matches}
      teamsByGroup={teamsByGroup}
      standings={standings}
      initialMessages={(msgs ?? []) as ChatMessage[]}
    />
  );
}
