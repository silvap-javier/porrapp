"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { savePrediction } from "@/lib/prediction-actions";
import { isMatchOpen, scoreMatch } from "@/lib/scoring";
import { formatKickoff } from "@/lib/format";

type Side = { flag: string; name: string };

export default function MatchCard({
  matchId,
  home,
  away,
  kickoffAt,
  status,
  homeScore,
  awayScore,
  initialHome,
  initialAway,
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
  initialHome: number | null;
  initialAway: number | null;
  venue?: string | null;
  tag?: string | null;
}) {
  const t = useTranslations("matches");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const open = isMatchOpen(kickoffAt, status);
  const [h, setH] = useState(initialHome?.toString() ?? "");
  const [a, setA] = useState(initialAway?.toString() ?? "");
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const finished = status === "finished" && homeScore !== null && awayScore !== null;
  const hasPred = initialHome !== null && initialAway !== null;
  const points =
    finished && hasPred
      ? scoreMatch(initialHome!, initialAway!, homeScore!, awayScore!)
      : null;

  const save = () => {
    setError("");
    setSaved(false);
    startTransition(async () => {
      const res = await savePrediction({
        matchId,
        homeScore: parseInt(h || "0", 10),
        awayScore: parseInt(a || "0", 10),
      });
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      setSaved(true);
      router.refresh();
    });
  };

  const dirty =
    h !== "" &&
    a !== "" &&
    (parseInt(h, 10) !== initialHome || parseInt(a, 10) !== initialAway);

  const onScore = (setter: (v: string) => void) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setter(e.target.value);
    if (saved) setSaved(false);
  };
  const inputClass =
    "w-12 h-10 text-center text-base rounded-lg border border-border bg-background disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50";

  return (
    <div className="bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)]">
      {/* Cabecera: badge grupo + estado */}
      <div className="flex items-center justify-between gap-2 mb-1.5">
        {tag ? (
          <span className="text-[11px] font-semibold text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {tag}
          </span>
        ) : (
          <span />
        )}
        {finished ? (
          <span className="text-[11px] font-medium text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {t("final")}
          </span>
        ) : open ? (
          <span className="text-[11px] font-medium text-secondary">{t("open")}</span>
        ) : (
          <span className="text-[11px] font-medium text-muted">🔒 {t("locked")}</span>
        )}
      </div>

      {/* Meta: fecha · sede */}
      <p className="text-xs text-muted mb-3 leading-snug">
        {formatKickoff(kickoffAt)}
        {venue ? <span className="block sm:inline sm:before:content-['_·_']">📍 {venue}</span> : null}
      </p>

      {/* Filas de equipos */}
      <div className="space-y-2">
        <div className="flex items-center justify-between gap-3">
          <span className="flex items-center gap-2 min-w-0">
            <span className="text-xl flex-shrink-0">{home.flag}</span>
            <span className="text-sm font-medium text-foreground leading-tight">{home.name}</span>
          </span>
          <div className="flex items-center gap-2 flex-shrink-0">
            {finished && (
              <span className="text-sm font-bold text-foreground tabular-nums w-4 text-center">
                {homeScore}
              </span>
            )}
            <input
              type="number"
              min={0}
              max={99}
              inputMode="numeric"
              value={h}
              disabled={!open || isPending}
              onChange={onScore(setH)}
              className={inputClass}
              placeholder="-"
            />
          </div>
        </div>
        <div className="flex items-center justify-between gap-3">
          <span className="flex items-center gap-2 min-w-0">
            <span className="text-xl flex-shrink-0">{away.flag}</span>
            <span className="text-sm font-medium text-foreground leading-tight">{away.name}</span>
          </span>
          <div className="flex items-center gap-2 flex-shrink-0">
            {finished && (
              <span className="text-sm font-bold text-foreground tabular-nums w-4 text-center">
                {awayScore}
              </span>
            )}
            <input
              type="number"
              min={0}
              max={99}
              inputMode="numeric"
              value={a}
              disabled={!open || isPending}
              onChange={onScore(setA)}
              className={inputClass}
              placeholder="-"
            />
          </div>
        </div>
      </div>

      {/* Pie: puntos / tu pronóstico + Guardar */}
      <div className="flex items-center justify-between gap-2 mt-3 min-h-8">
        <div className="text-xs">
          {points !== null && (
            <span
              className={`font-semibold px-2 py-0.5 rounded-full ${
                points > 0 ? "text-primary bg-primary/10" : "text-muted bg-surface-hover"
              }`}
            >
              +{points} {t("points")}
            </span>
          )}
          {!finished && hasPred && !dirty && (
            <span className="text-muted">
              {t("yourPick")}: {initialHome}–{initialAway}
            </span>
          )}
        </div>

        {open && (
          <button
            onClick={save}
            disabled={isPending || !dirty}
            className="text-sm bg-primary text-white px-5 py-1.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-40 flex-shrink-0"
          >
            {saved && !dirty ? `✓ ${t("saved")}` : isPending ? t("saving") : t("save")}
          </button>
        )}
      </div>
      {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
    </div>
  );
}
