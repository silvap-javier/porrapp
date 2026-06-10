"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { saveGroupPositions } from "@/lib/picks-actions";
import type { Team } from "@/lib/types";

type GroupData = { letter: string; teams: Team[] };

export default function GroupPositionsForm({
  groups,
  initial,
  locked,
}: {
  groups: GroupData[];
  initial: Record<string, { first: string | null; second: string | null }>;
  locked: boolean;
}) {
  const t = useTranslations("picks");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [picks, setPicks] = useState<Record<string, { first: string; second: string }>>(() => {
    const init: Record<string, { first: string; second: string }> = {};
    for (const g of groups) {
      init[g.letter] = {
        first: initial[g.letter]?.first ?? "",
        second: initial[g.letter]?.second ?? "",
      };
    }
    return init;
  });
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const set = (group: string, key: "first" | "second", value: string) => {
    setPicks((p) => ({ ...p, [group]: { ...p[group], [key]: value } }));
    if (saved) setSaved(false);
  };

  const save = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setSaved(false);
    startTransition(async () => {
      const res = await saveGroupPositions(
        groups.map((g) => ({
          group: g.letter,
          firstTeamId: picks[g.letter].first || null,
          secondTeamId: picks[g.letter].second || null,
        }))
      );
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      setSaved(true);
      router.refresh();
    });
  };

  return (
    <form onSubmit={save} className="space-y-4">
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

      <div className="space-y-3">
        {groups.map((g) => {
          const opts = g.teams;
          const sel = picks[g.letter];
          return (
            <div key={g.letter} className="bg-surface border border-border rounded-2xl p-3">
              <p className="text-sm font-semibold text-foreground mb-2">
                {t("group")} {g.letter}
              </p>
              <div className="grid grid-cols-2 gap-2">
                <label className="text-xs text-muted">
                  🥇 {t("first")} <span className="text-foreground">· 3 {t("pts")}</span>
                  <select
                    value={sel.first}
                    disabled={locked || isPending}
                    onChange={(e) => set(g.letter, "first", e.target.value)}
                    className="mt-1 w-full px-3 py-2 rounded-lg border border-border bg-background text-foreground disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
                  >
                    <option value="">—</option>
                    {opts.map((tm) => (
                      <option key={tm.id} value={tm.id} disabled={sel.second === tm.id}>
                        {tm.flag_emoji} {tm.name}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="text-xs text-muted">
                  🥈 {t("second")} <span className="text-foreground">· 2 {t("pts")}</span>
                  <select
                    value={sel.second}
                    disabled={locked || isPending}
                    onChange={(e) => set(g.letter, "second", e.target.value)}
                    className="mt-1 w-full px-3 py-2 rounded-lg border border-border bg-background text-foreground disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
                  >
                    <option value="">—</option>
                    {opts.map((tm) => (
                      <option key={tm.id} value={tm.id} disabled={sel.first === tm.id}>
                        {tm.flag_emoji} {tm.name}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
            </div>
          );
        })}
      </div>

      {!locked && (
        <div className="sticky bottom-0 bg-background py-2 flex items-center gap-3">
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
