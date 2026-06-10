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

  return (
    <div className="bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)]">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs text-muted">{formatKickoff(kickoffAt)}</span>
        {finished ? (
          <span className="text-xs font-medium text-primary bg-primary/10 px-2 py-0.5 rounded-full">
            {t("final")} {homeScore}–{awayScore}
          </span>
        ) : open ? (
          <span className="text-xs font-medium text-secondary">{t("open")}</span>
        ) : (
          <span className="text-xs font-medium text-muted">🔒 {t("locked")}</span>
        )}
      </div>

      <div className="flex items-center justify-between gap-3">
        <div className="flex-1 text-right">
          <span className="text-sm font-medium text-foreground">
            {home.flag} {home.name}
          </span>
        </div>

        <div className="flex items-center gap-1.5">
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={h}
            disabled={!open || isPending}
            onChange={(e) => {
              setH(e.target.value);
              if (saved) setSaved(false);
            }}
            className="w-12 text-center px-2 py-1.5 rounded-lg border border-border bg-background disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
            placeholder="-"
          />
          <span className="text-muted">–</span>
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={a}
            disabled={!open || isPending}
            onChange={(e) => {
              setA(e.target.value);
              if (saved) setSaved(false);
            }}
            className="w-12 text-center px-2 py-1.5 rounded-lg border border-border bg-background disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
            placeholder="-"
          />
        </div>

        <div className="flex-1 text-left">
          <span className="text-sm font-medium text-foreground">
            {away.name} {away.flag}
          </span>
        </div>
      </div>

      <div className="flex items-center justify-between mt-3 min-h-6">
        <div className="text-xs">
          {points !== null && (
            <span
              className={`font-semibold px-2 py-0.5 rounded-full ${
                points > 0
                  ? "text-primary bg-primary/10"
                  : "text-muted bg-surface-hover"
              }`}
            >
              +{points} {t("points")}
            </span>
          )}
          {!finished && hasPred && !dirty && (
            <span className="text-muted">{t("yourPick")}: {initialHome}–{initialAway}</span>
          )}
        </div>

        {open && (
          <button
            onClick={save}
            disabled={isPending || !dirty}
            className="text-xs bg-primary text-white px-4 py-1.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-40"
          >
            {saved ? `✓ ${t("saved")}` : isPending ? t("saving") : t("save")}
          </button>
        )}
      </div>
      {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
    </div>
  );
}
