"use client";

import { useMemo, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import LaPorritaView, { type LMatch } from "@/components/LaPorritaView";
import LeagueActions from "@/components/LeagueActions";
import ChatTab from "@/components/ChatTab";
import { formatDay } from "@/lib/format";
import { STAGE_LABELS, type Stage, type LeaderboardRow } from "@/lib/types";
import type { ChatMessage } from "@/lib/chat-actions";

export type PhaseRow = {
  user_id: string;
  stage: string;
  exact_count: number;
  result_count: number;
  points: number;
};

export type GroupStanding = {
  group: string;
  rows: {
    flag: string;
    name: string;
    pj: number;
    g: number;
    e: number;
    p: number;
    gf: number;
    gc: number;
    dg: number;
    pts: number;
  }[];
};

type League = {
  id: string;
  name: string;
  joinCode: string;
  isOwner: boolean;
  memberCount: number;
  entryFee: number;
};

const TABS = ["ranking", "porrita", "mundial", "calendario", "chat"] as const;
type Tab = (typeof TABS)[number];
const TAB_ICON: Record<Tab, string> = {
  ranking: "📊",
  porrita: "⚽",
  mundial: "🏆",
  calendario: "📅",
  chat: "💬",
};
const STAGE_ORDER: Stage[] = ["group", "r32", "r16", "qf", "sf", "third", "final"];

export default function LeagueHub({
  league,
  currentUserId,
  leaderboard,
  breakdown,
  maxByStage,
  matches,
  teamsByGroup,
  standings,
  initialMessages,
}: {
  league: League;
  currentUserId: string;
  leaderboard: LeaderboardRow[];
  breakdown: PhaseRow[];
  maxByStage: Record<string, number>;
  matches: LMatch[];
  teamsByGroup: Record<string, { flag: string; name: string }[]>;
  standings: GroupStanding[];
  initialMessages: ChatMessage[];
}) {
  const t = useTranslations("hub");
  const [tab, setTab] = useState<Tab>("porrita");
  const [showInfo, setShowInfo] = useState(false);

  return (
    <div className="max-w-2xl mx-auto pb-10">
      {/* Cabecera */}
      <header className="px-3 pt-4">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 min-w-0">
            <Link href="/dashboard" className="text-muted hover:text-foreground text-xl flex-shrink-0">
              ←
            </Link>
            <div className="min-w-0">
              <h1 className="text-xl font-bold text-foreground font-display truncate">{league.name}</h1>
              <p className="text-xs text-muted">
                Mundial 2026 · 👥 {league.memberCount}
                {league.entryFee > 0 && (
                  <span className="text-secondary">
                    {" "}· 💰 {(league.entryFee * league.memberCount).toLocaleString("es-ES")} €
                  </span>
                )}
              </p>
            </div>
          </div>
          <button
            onClick={() => setShowInfo((s) => !s)}
            className="text-sm flex-shrink-0 bg-surface border border-border px-3 py-1.5 rounded-full hover:border-primary/40 transition-colors"
          >
            {showInfo ? "✕" : t("invite")}
          </button>
        </div>

        {showInfo && (
          <div className="mt-3 bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)]">
            <LeagueActions
              leagueId={league.id}
              joinCode={league.joinCode}
              isOwner={league.isOwner}
              entryFee={league.entryFee}
              memberCount={league.memberCount}
            />
          </div>
        )}
      </header>

      {/* Tabs */}
      <nav className="flex border-b border-border mt-3 px-1 sticky top-14 bg-background z-10">
        {TABS.map((tb) => (
          <button
            key={tb}
            onClick={() => setTab(tb)}
            className={`flex-1 flex flex-col items-center gap-0.5 py-2 text-xs font-medium border-b-2 -mb-px transition-colors ${
              tab === tb
                ? "border-secondary text-foreground"
                : "border-transparent text-muted hover:text-foreground"
            }`}
          >
            <span className="text-base">{TAB_ICON[tb]}</span>
            {t(tb)}
          </button>
        ))}
      </nav>

      <div className="px-3 pt-4">
        {tab === "ranking" && (
          <RankingTab
            leaderboard={leaderboard}
            breakdown={breakdown}
            maxByStage={maxByStage}
            currentUserId={currentUserId}
          />
        )}
        {tab === "porrita" && <LaPorritaView matches={matches} teamsByGroup={teamsByGroup} />}
        {tab === "mundial" && <MundialTab standings={standings} matches={matches} />}
        {tab === "calendario" && <CalendarioTab matches={matches} />}
        {tab === "chat" && (
          <ChatTab
            leagueId={league.id}
            currentUserId={currentUserId}
            members={leaderboard.map((r) => ({ id: r.user_id, name: r.name || r.email }))}
            initialMessages={initialMessages}
          />
        )}
      </div>
    </div>
  );
}

/* ---------------- Ranking ---------------- */

function RankingTab({
  leaderboard,
  breakdown,
  maxByStage,
  currentUserId,
}: {
  leaderboard: LeaderboardRow[];
  breakdown: PhaseRow[];
  maxByStage: Record<string, number>;
  currentUserId: string;
}) {
  const t = useTranslations("hub");
  const [openUser, setOpenUser] = useState<string | null>(null);

  const byUser = useMemo(() => {
    const m = new Map<string, Map<string, PhaseRow>>();
    for (const r of breakdown) {
      if (!m.has(r.user_id)) m.set(r.user_id, new Map());
      m.get(r.user_id)!.set(r.stage, r);
    }
    return m;
  }, [breakdown]);

  const stages = STAGE_ORDER.filter((s) => (maxByStage[s] ?? 0) > 0);

  if (leaderboard.length === 0) {
    return <p className="text-sm text-muted">{t("noPlayers")}</p>;
  }

  return (
    <div className="space-y-2">
      {leaderboard.map((r, i) => {
        const open = openUser === r.user_id;
        const me = r.user_id === currentUserId;
        const ub = byUser.get(r.user_id);
        return (
          <div
            key={r.user_id}
            className={`bg-surface border rounded-2xl overflow-hidden ${me ? "border-primary" : "border-border"}`}
          >
            <button
              onClick={() => setOpenUser(open ? null : r.user_id)}
              className="w-full flex items-center gap-3 px-3 py-3"
            >
              <span className="w-7 h-7 rounded-full bg-surface-hover flex items-center justify-center text-xs font-bold text-muted flex-shrink-0">
                {i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : i + 1}
              </span>
              <span className="flex-1 min-w-0 text-left">
                <span className="block text-sm font-medium text-foreground truncate">
                  {r.name || r.email}
                </span>
                <span className="text-xs text-muted">
                  🎯 {r.exact_count} · ✓ {r.result_count}
                </span>
              </span>
              <span className="text-lg font-bold text-foreground flex-shrink-0">{r.total_points}</span>
              <span className="text-muted flex-shrink-0">{open ? "▲" : "▼"}</span>
            </button>

            {open && (
              <div className="border-t border-border px-3 py-2 bg-background/40">
                <p className="text-xs font-semibold text-secondary mb-1.5">{t("breakdown")}</p>
                <div className="space-y-1">
                  {stages.map((s) => {
                    const row = ub?.get(s);
                    const pts = row?.points ?? 0;
                    const max = maxByStage[s] ?? 0;
                    return (
                      <div key={s} className="flex items-center gap-2 text-xs">
                        <span className="flex-1 text-foreground">{STAGE_LABELS[s]}</span>
                        <span className="text-muted">🎯 {row?.exact_count ?? 0}</span>
                        <span className="text-muted">✓ {row?.result_count ?? 0}</span>
                        <span className="font-semibold text-foreground tabular-nums w-14 text-right">
                          {pts} / {max}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

/* ---------------- Mundial ---------------- */

function MundialTab({ standings, matches }: { standings: GroupStanding[]; matches: LMatch[] }) {
  const t = useTranslations("hub");
  const played = matches.filter((m) => m.status === "finished").length;

  return (
    <div className="space-y-3">
      <div className="bg-surface border border-border rounded-2xl p-4 flex items-center gap-3">
        <span className="text-2xl">🏆</span>
        <div>
          <p className="font-semibold text-foreground">{t("worldCupStatus")}</p>
          <p className="text-xs text-muted">
            {played} / {matches.length} {t("matchesPlayed")}
          </p>
        </div>
      </div>

      {standings.map((s) => (
        <div key={s.group} className="rounded-2xl overflow-hidden border border-border">
          <div className="bg-gradient-to-r from-primary to-primary-dark px-4 py-2">
            <span className="font-bold text-white">{t("group")} {s.group}</span>
          </div>
          <table className="w-full text-sm bg-surface">
            <thead>
              <tr className="text-[11px] text-muted">
                <th className="text-left font-medium pl-3 py-1.5 w-5"></th>
                <th className="text-left font-medium py-1.5"></th>
                <th className="text-center font-medium px-1 w-8">PJ</th>
                <th className="text-center font-medium px-1 w-8">DG</th>
                <th className="text-center font-medium pr-3 px-1 w-8">Pts</th>
              </tr>
            </thead>
            <tbody>
              {s.rows.map((r, i) => (
                <tr key={r.name} className="border-t border-border/60">
                  <td className="pl-3 py-1.5 text-xs text-muted">{i + 1}</td>
                  <td className="py-1.5">
                    <span className="text-base mr-1.5">{r.flag}</span>
                    <span className="text-sm text-foreground">{r.name}</span>
                  </td>
                  <td className="text-center text-xs text-muted">{r.pj}</td>
                  <td className="text-center text-xs text-muted">{r.dg > 0 ? `+${r.dg}` : r.dg}</td>
                  <td className="text-center pr-3 text-sm font-bold text-foreground">{r.pts}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}

/* ---------------- Calendario ---------------- */

function CalendarioTab({ matches }: { matches: LMatch[] }) {
  // Agrupa por día local del usuario.
  const days = useMemo(() => {
    const map = new Map<string, LMatch[]>();
    const sorted = [...matches].sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt));
    for (const m of sorted) {
      const d = new Date(m.kickoffAt);
      const key = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
      (map.get(key) ?? map.set(key, []).get(key)!).push(m);
    }
    return Array.from(map.values());
  }, [matches]);

  const timeFmt = (iso: string) =>
    new Date(iso).toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" });

  return (
    <div className="space-y-4">
      {days.map((dayMatches, idx) => (
        <div key={idx}>
          <h3 className="text-sm font-semibold text-foreground bg-primary/10 px-3 py-1.5 rounded-lg mb-2 capitalize">
            {formatDay(dayMatches[0].kickoffAt)}
          </h3>
          <div className="space-y-1.5">
            {dayMatches.map((m) => (
              <div key={m.id} className="flex items-center gap-3 bg-surface border border-border rounded-xl px-3 py-2">
                <span className="text-sm font-semibold text-foreground tabular-nums w-12 flex-shrink-0">
                  {timeFmt(m.kickoffAt)}
                </span>
                <span className="text-[10px] text-muted w-12 flex-shrink-0">
                  {m.group ? `${m.group} · ` : ""}M{m.matchNumber}
                </span>
                <div className="flex-1 min-w-0 text-sm">
                  <div className="flex items-center gap-1.5 truncate">
                    <span>{m.home.flag}</span>
                    <span className="text-foreground truncate">{m.home.name}</span>
                  </div>
                  <div className="flex items-center gap-1.5 truncate">
                    <span>{m.away.flag}</span>
                    <span className="text-foreground truncate">{m.away.name}</span>
                  </div>
                </div>
                {m.status === "finished" ? (
                  <span className="text-sm font-bold text-foreground flex-shrink-0">
                    {m.homeScore}-{m.awayScore}
                  </span>
                ) : (
                  <span className="text-xs text-muted flex-shrink-0">vs</span>
                )}
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
