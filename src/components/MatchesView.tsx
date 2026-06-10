"use client";

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import MatchCard from "./MatchCard";
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

  const visible = matches.filter(
    (m) =>
      m.stage === stage &&
      (stage !== "group" || group === "all" || m.group_letter === group)
  );

  const predicted = visible.filter((m) => m.predHome !== null).length;

  return (
    <div className="space-y-4">
      {/* Pestañas por fase */}
      <div className="flex gap-1.5 overflow-x-auto pb-1 -mx-1 px-1">
        {stages.map((s) => (
          <button
            key={s}
            onClick={() => setStage(s)}
            className={`whitespace-nowrap text-sm px-3.5 py-1.5 rounded-full font-medium transition-colors ${
              stage === s
                ? "bg-primary text-white"
                : "bg-surface border border-border text-muted hover:text-foreground"
            }`}
          >
            {STAGE_SHORT[s]}
          </button>
        ))}
      </div>

      {/* Chips por grupo (solo en fase de grupos) */}
      {stage === "group" && groups.length > 0 && (
        <div className="flex gap-1.5 overflow-x-auto pb-1 -mx-1 px-1">
          <GroupChip active={group === "all"} onClick={() => setGroup("all")} label={t("allGroups")} />
          {groups.map((g) => (
            <GroupChip
              key={g}
              active={group === g}
              onClick={() => setGroup(g)}
              label={g}
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
          <div key={m.id}>
            {stage === "group" && group === "all" && m.group_letter && (
              <span className="text-xs text-muted ml-1">
                {t("group")} {m.group_letter}
              </span>
            )}
            <MatchCard
              matchId={m.id}
              home={m.home}
              away={m.away}
              kickoffAt={m.kickoff_at}
              status={m.status}
              homeScore={m.home_score}
              awayScore={m.away_score}
              initialHome={m.predHome}
              initialAway={m.predAway}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

function GroupChip({
  active,
  onClick,
  label,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
}) {
  return (
    <button
      onClick={onClick}
      className={`whitespace-nowrap text-sm w-9 h-9 flex items-center justify-center rounded-full font-semibold transition-colors ${
        active
          ? "bg-secondary text-foreground"
          : "bg-surface border border-border text-muted hover:text-foreground"
      } ${label.length > 2 ? "w-auto px-3" : ""}`}
    >
      {label}
    </button>
  );
}
