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
  tag,
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
  tag?: string | null;
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

  const inputClass =
    "w-12 h-9 text-center text-base rounded-lg border border-border bg-background focus:outline-none focus:ring-2 focus:ring-primary/50";

  return (
    <div className="bg-surface border border-border rounded-xl px-3.5 py-3 shadow-[var(--shadow-warm)]">
      <div className="flex items-center justify-between gap-2 mb-1">
        {tag ? (
          <span className="text-[11px] font-semibold text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {tag}
          </span>
        ) : (
          <span />
        )}
        {status === "finished" ? (
          <span className="text-[11px] font-medium text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {t("finished")}
          </span>
        ) : (
          <span className="text-[11px] font-medium text-muted">{t("pending")}</span>
        )}
      </div>

      <p className="text-[11px] text-muted mb-2 truncate">
        {formatKickoff(kickoffAt)}
        {venue ? ` · 📍 ${venue}` : ""}
      </p>

      <div className="space-y-1.5">
        <div className="flex items-center justify-between gap-3">
          <span className="flex items-center gap-2 min-w-0">
            <span className="text-xl flex-shrink-0">{home.flag}</span>
            <span className="text-sm font-medium text-foreground leading-tight">{home.name}</span>
          </span>
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={h}
            disabled={isPending}
            onChange={(e) => setH(e.target.value)}
            className={inputClass}
            placeholder="-"
          />
        </div>
        <div className="flex items-center justify-between gap-3">
          <span className="flex items-center gap-2 min-w-0">
            <span className="text-xl flex-shrink-0">{away.flag}</span>
            <span className="text-sm font-medium text-foreground leading-tight">{away.name}</span>
          </span>
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={a}
            disabled={isPending}
            onChange={(e) => setA(e.target.value)}
            className={inputClass}
            placeholder="-"
          />
        </div>
      </div>

      <div className="flex items-center justify-between gap-2 mt-2">
        <span className="text-xs text-muted truncate">
          {setByName ? `${t("setBy")} ${setByName}` : ""}
        </span>
        <div className="flex items-center gap-2 flex-shrink-0">
          {status === "finished" && (
            <button
              onClick={clear}
              disabled={isPending}
              className="text-xs text-muted hover:text-red-600 px-2 py-1.5 transition-colors disabled:opacity-40"
            >
              {t("reopen")}
            </button>
          )}
          <button
            onClick={save}
            disabled={isPending || h === "" || a === ""}
            className="text-sm bg-primary text-white px-5 py-1.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-40"
          >
            {isPending ? t("saving") : t("save")}
          </button>
        </div>
      </div>
      {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
    </div>
  );
}
