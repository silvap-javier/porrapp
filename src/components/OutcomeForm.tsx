"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { setTournamentOutcome } from "@/lib/match-actions";
import type { Team } from "@/lib/types";

export default function OutcomeForm({
  teams,
  initialChampion,
  initialRunnerup,
  initialTopScorer,
}: {
  teams: Team[];
  initialChampion: string | null;
  initialRunnerup: string | null;
  initialTopScorer: string | null;
}) {
  const t = useTranslations("results");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [champion, setChampion] = useState(initialChampion ?? "");
  const [runnerup, setRunnerup] = useState(initialRunnerup ?? "");
  const [topScorer, setTopScorer] = useState(initialTopScorer ?? "");
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const save = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setSaved(false);
    startTransition(async () => {
      const res = await setTournamentOutcome({
        championTeamId: champion || null,
        runnerupTeamId: runnerup || null,
        topScorer,
      });
      if ("error" in res) setError(tErr(res.error));
      else {
        setSaved(true);
        router.refresh();
      }
    });
  };

  return (
    <form onSubmit={save} className="space-y-4">
      {error && (
        <div className="bg-red-500/10 text-red-600 text-sm p-3 rounded-lg border border-red-500/25">
          {error}
        </div>
      )}
      <div className="grid sm:grid-cols-3 gap-3">
        <div>
          <label className="block text-sm font-medium text-foreground mb-1">{t("champion")}</label>
          <select
            value={champion}
            onChange={(e) => setChampion(e.target.value)}
            className="w-full px-3 py-2 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50"
          >
            <option value="">—</option>
            {teams.map((tm) => (
              <option key={tm.id} value={tm.id}>{tm.flag_emoji} {tm.name}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium text-foreground mb-1">{t("runnerup")}</label>
          <select
            value={runnerup}
            onChange={(e) => setRunnerup(e.target.value)}
            className="w-full px-3 py-2 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50"
          >
            <option value="">—</option>
            {teams.map((tm) => (
              <option key={tm.id} value={tm.id}>{tm.flag_emoji} {tm.name}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium text-foreground mb-1">{t("topScorer")}</label>
          <input
            type="text"
            value={topScorer}
            maxLength={80}
            onChange={(e) => setTopScorer(e.target.value)}
            className="w-full px-3 py-2 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50"
            placeholder="—"
          />
        </div>
      </div>
      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={isPending}
          className="bg-primary text-white px-5 py-2 rounded-full text-sm font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
        >
          {isPending ? t("saving") : t("save")}
        </button>
        {saved && <span className="text-sm text-primary">✓ {t("saved")}</span>}
      </div>
    </form>
  );
}
