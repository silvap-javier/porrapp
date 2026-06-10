"use client";

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import MatchCard from "./MatchCard";
import { isMatchOpen } from "@/lib/scoring";
import type { Stage } from "@/lib/types";

type Side = { flag: string; name: string };

export type ViewMatch = {
  id: string;
  stage: Stage;
  group_letter: string | null;
  kickoff_at: string;
  status: "scheduled" | "finished";
  home_score: number | null;
  away_score: number | null;
  home: Side;
  away: Side;
  venue: string | null;
  predHome: number | null;
  predAway: number | null;
};

const STAGE_ORDER: Stage[] = ["group", "r32", "r16", "qf", "sf", "third", "final"];
const STAGE_SHORT: Record<Stage, string> = {
  group: "Grupos",
  r32: "16avos",
  r16: "Octavos",
  qf: "Cuartos",
  sf: "Semis",
  third: "3.º",
  final: "Final",
};

export default function MatchesView({ matches }: { matches: ViewMatch[] }) {
  const t = useTranslations("matches");

  const stages = useMemo(
    () => STAGE_ORDER.filter((s) => matches.some((m) => m.stage === s)),
    [matches]
  );
  const groups = useMemo(
    () =>
      Array.from(
        new Set(
          matches
            .filter((m) => m.stage === "group" && m.group_letter)
            .map((m) => m.group_letter as string)
        )
      ).sort(),
    [matches]
  );

  const [stage, setStage] = useState<Stage>(stages[0] ?? "group");
  const [group, setGroup] = useState<string>("all");

  // Pendiente = partido abierto (aún se puede pronosticar) y sin pronóstico.
  const isPending = (m: ViewMatch) =>
    isMatchOpen(m.kickoff_at, m.status) && m.predHome === null;

  const pendingByStage = useMemo(() => {
    const map = new Map<Stage, number>();
    for (const m of matches) {
      if (isPending(m)) map.set(m.stage, (map.get(m.stage) ?? 0) + 1);
    }
    return map;
  }, [matches]);

  const pendingByGroup = useMemo(() => {
    const map = new Map<string, number>();
    for (const m of matches) {
      if (m.stage === "group" && m.group_letter && isPending(m)) {
        map.set(m.group_letter, (map.get(m.group_letter) ?? 0) + 1);
      }
    }
    return map;
  }, [matches]);

  const groupsPendingTotal = useMemo(
    () => Array.from(pendingByGroup.values()).reduce((a, b) => a + b, 0),
    [pendingByGroup]
  );

  const visible = matches.filter(
    (m) =>
      m.stage === stage &&
      (stage !== "group" || group === "all" || m.group_letter === group)
  );

  const predicted = visible.filter((m) => m.predHome !== null).length;

  return (
    <div className="space-y-4">
      {/* Pestañas por fase */}
      <div className="flex flex-wrap gap-1.5">
        {stages.map((s) => (
          <button
            key={s}
            onClick={() => setStage(s)}
            className={`relative whitespace-nowrap text-sm px-3.5 py-1.5 rounded-full font-medium transition-colors ${
              stage === s
                ? "bg-primary text-white"
                : "bg-surface border border-border text-muted hover:text-foreground"
            }`}
          >
            {STAGE_SHORT[s]}
            {(pendingByStage.get(s) ?? 0) > 0 && (
              <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-accent ring-2 ring-background" />
            )}
          </button>
        ))}
      </div>

      {/* Chips por grupo (solo en fase de grupos) */}
      {stage === "group" && groups.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          <GroupChip
            active={group === "all"}
            onClick={() => setGroup("all")}
            label={t("allGroups")}
            pending={groupsPendingTotal > 0}
          />
          {groups.map((g) => (
            <GroupChip
              key={g}
              active={group === g}
              onClick={() => setGroup(g)}
              label={g}
              pending={(pendingByGroup.get(g) ?? 0) > 0}
            />
          ))}
        </div>
      )}

      {/* Contador */}
      <p className="text-xs text-muted">
        {predicted}/{visible.length} {t("predictedCount")}
      </p>

      {/* Lista */}
      <div className="space-y-3">
        {visible.map((m) => (
          <MatchCard
            key={m.id}
            matchId={m.id}
            home={m.home}
            away={m.away}
            kickoffAt={m.kickoff_at}
            status={m.status}
            homeScore={m.home_score}
            awayScore={m.away_score}
            initialHome={m.predHome}
            initialAway={m.predAway}
            venue={m.venue}
            tag={
              stage === "group" && group === "all" && m.group_letter
                ? `${t("group")} ${m.group_letter}`
                : undefined
            }
          />
        ))}
      </div>
    </div>
  );
}

function GroupChip({
  active,
  onClick,
  label,
  pending,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  pending?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className={`relative whitespace-nowrap text-sm w-9 h-9 flex items-center justify-center rounded-full font-semibold transition-colors ${
        active
          ? "bg-secondary text-foreground"
          : "bg-surface border border-border text-muted hover:text-foreground"
      } ${label.length > 2 ? "w-auto px-3" : ""}`}
    >
      {label}
      {pending && (
        <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-accent ring-2 ring-background" />
      )}
    </button>
  );
}
