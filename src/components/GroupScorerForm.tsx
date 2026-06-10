"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { saveGroupTopScorers } from "@/lib/picks-actions";
import { setGroupTopScorers } from "@/lib/match-actions";
import type { GroupPlayersData } from "@/lib/types";

export default function GroupScorerForm({
  groups,
  initial,
  locked = false,
  mode,
}: {
  groups: GroupPlayersData[];
  initial: Record<string, string>;
  locked?: boolean;
  mode: "pick" | "outcome";
}) {
  const t = useTranslations("picks");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [picks, setPicks] = useState<Record<string, string>>(() => {
    const init: Record<string, string> = {};
    for (const g of groups) init[g.letter] = initial[g.letter] ?? "";
    return init;
  });
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const set = (group: string, value: string) => {
    setPicks((p) => ({ ...p, [group]: value }));
    if (saved) setSaved(false);
  };

  const save = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setSaved(false);
    startTransition(async () => {
      const payload = groups.map((g) => ({ group: g.letter, playerId: picks[g.letter] || null }));
      const res =
        mode === "pick"
          ? await saveGroupTopScorers(payload)
          : await setGroupTopScorers(payload);
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      setSaved(true);
      router.refresh();
    });
  };

  return (
    <form onSubmit={save} className="space-y-3">
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

      <div className="space-y-2">
        {groups.map((g) => (
          <div key={g.letter} className="bg-surface border border-border rounded-xl p-3">
            <label className="block text-sm font-semibold text-foreground mb-1.5">
              {t("group")} {g.letter}
              {mode === "pick" && <span className="text-xs text-muted font-normal"> · 3 {t("pts")}</span>}
            </label>
            <select
              value={picks[g.letter]}
              disabled={locked || isPending}
              onChange={(e) => set(g.letter, e.target.value)}
              className="w-full px-3 py-2 rounded-lg border border-border bg-background text-foreground disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
            >
              <option value="">— {t("choosePlayer")} —</option>
              {g.teams.map((team) => (
                <optgroup key={team.name} label={`${team.flag} ${team.name}`}>
                  {team.players.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                      {p.position ? ` · ${p.position}` : ""}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          </div>
        ))}
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
