"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { setMatchResult, clearMatchResult } from "@/lib/match-actions";
import { formatKickoff } from "@/lib/format";

type Side = { flag: string; name: string };

export default function ResultCard({
  matchId,
  home,
  away,
  kickoffAt,
  status,
  homeScore,
  awayScore,
  setByName,
  venue,
}: {
  matchId: string;
  home: Side;
  away: Side;
  kickoffAt: string;
  status: "scheduled" | "finished";
  homeScore: number | null;
  awayScore: number | null;
  setByName: string | null;
  venue?: string | null;
}) {
  const t = useTranslations("results");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [h, setH] = useState(homeScore?.toString() ?? "");
  const [a, setA] = useState(awayScore?.toString() ?? "");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const save = () => {
    setError("");
    startTransition(async () => {
      const res = await setMatchResult({
        matchId,
        homeScore: parseInt(h || "0", 10),
        awayScore: parseInt(a || "0", 10),
      });
      if ("error" in res) setError(tErr(res.error));
      else router.refresh();
    });
  };

  const clear = () => {
    if (!window.confirm(t("confirmClear"))) return;
    setError("");
    startTransition(async () => {
      const res = await clearMatchResult(matchId);
      if ("error" in res) setError(tErr(res.error));
      else {
        setH("");
        setA("");
        router.refresh();
      }
    });
  };

  return (
    <div className="bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)]">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs text-muted">
          {formatKickoff(kickoffAt)}
          {venue ? ` · ${venue}` : ""}
        </span>
        {status === "finished" ? (
          <span className="text-xs font-medium text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {t("finished")}
          </span>
        ) : (
          <span className="text-xs font-medium text-muted">{t("pending")}</span>
        )}
      </div>

      <div className="flex items-center justify-between gap-3">
        <span className="flex-1 text-right text-sm font-medium text-foreground">
          {home.flag} {home.name}
        </span>
        <div className="flex items-center gap-1.5">
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={h}
            disabled={isPending}
            onChange={(e) => setH(e.target.value)}
            className="w-12 text-center px-2 py-1.5 rounded-lg border border-border bg-background focus:outline-none focus:ring-2 focus:ring-primary/50"
            placeholder="-"
          />
          <span className="text-muted">–</span>
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={a}
            disabled={isPending}
            onChange={(e) => setA(e.target.value)}
            className="w-12 text-center px-2 py-1.5 rounded-lg border border-border bg-background focus:outline-none focus:ring-2 focus:ring-primary/50"
            placeholder="-"
          />
        </div>
        <span className="flex-1 text-left text-sm font-medium text-foreground">
          {away.name} {away.flag}
        </span>
      </div>

      <div className="flex items-center justify-between mt-3">
        <span className="text-xs text-muted">
          {setByName ? `${t("setBy")} ${setByName}` : ""}
        </span>
        <div className="flex items-center gap-2">
          {status === "finished" && (
            <button
              onClick={clear}
              disabled={isPending}
              className="text-xs text-muted hover:text-red-600 px-3 py-1.5 transition-colors disabled:opacity-40"
            >
              {t("reopen")}
            </button>
          )}
          <button
            onClick={save}
            disabled={isPending || h === "" || a === ""}
            className="text-xs bg-primary text-white px-4 py-1.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-40"
          >
            {isPending ? t("saving") : t("save")}
          </button>
        </div>
      </div>
      {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
    </div>
  );
}
