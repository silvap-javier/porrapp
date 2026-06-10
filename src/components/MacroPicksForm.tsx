"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { saveMacroPicks } from "@/lib/picks-actions";
import type { Team } from "@/lib/types";

export default function MacroPicksForm({
  teams,
  initialChampion,
  initialRunnerup,
  initialTopScorer,
  locked,
}: {
  teams: Team[];
  initialChampion: string | null;
  initialRunnerup: string | null;
  initialTopScorer: string | null;
  locked: boolean;
}) {
  const t = useTranslations("picks");
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
      const res = await saveMacroPicks({
        championTeamId: champion || null,
        runnerupTeamId: runnerup || null,
        topScorer,
      });
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      setSaved(true);
      router.refresh();
    });
  };

  const onTeamChange = (setter: (v: string) => void) => (e: React.ChangeEvent<HTMLSelectElement>) => {
    setter(e.target.value);
    if (saved) setSaved(false);
  };

  const teamOptions = teams.map((tm) => (
    <option key={tm.id} value={tm.id}>
      {tm.flag_emoji} {tm.name}
    </option>
  ));

  return (
    <form onSubmit={save} className="space-y-5">
      {locked && (
        <div className="bg-secondary/15 border border-secondary/40 text-foreground text-sm p-3 rounded-lg">
          {t("lockedNotice")}
        </div>
      )}
      {error && (
        <div className="bg-red-500/10 text-red-600 text-sm p-3 rounded-lg border border-red-500/25">
          {error}
        </div>
      )}

      <div>
        <label className="block text-sm font-medium text-foreground mb-1">
          {t("champion")} <span className="text-xs text-muted">· 10 {t("pts")}</span>
        </label>
        <select
          value={champion}
          disabled={locked || isPending}
          onChange={onTeamChange(setChampion)}
          className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
        >
          <option value="">{t("choose")}</option>
          {teamOptions}
        </select>
      </div>

      <div>
        <label className="block text-sm font-medium text-foreground mb-1">
          {t("runnerup")} <span className="text-xs text-muted">· 5 {t("pts")}</span>
        </label>
        <select
          value={runnerup}
          disabled={locked || isPending}
          onChange={onTeamChange(setRunnerup)}
          className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
        >
          <option value="">{t("choose")}</option>
          {teamOptions}
        </select>
      </div>

      <div>
        <label className="block text-sm font-medium text-foreground mb-1">
          {t("topScorer")} <span className="text-xs text-muted">· 5 {t("pts")}</span>
        </label>
        <input
          type="text"
          value={topScorer}
          disabled={locked || isPending}
          maxLength={80}
          onChange={(e) => {
            setTopScorer(e.target.value);
            if (saved) setSaved(false);
          }}
          className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
          placeholder={t("topScorerPlaceholder")}
        />
      </div>

      {!locked && (
        <div className="flex items-center gap-3">
          <button
            type="submit"
            disabled={isPending}
            className="bg-primary text-white px-6 py-2.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
          >
            {isPending ? t("saving") : t("save")}
          </button>
          {saved && <span className="text-sm text-primary">✓ {t("saved")}</span>}
        </div>
      )}
    </form>
  );
}
