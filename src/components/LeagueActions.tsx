"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { leaveLeague, deleteLeague, updateLeagueFee } from "@/lib/leagues-actions";

export default function LeagueActions({
  leagueId,
  joinCode,
  isOwner,
  entryFee,
  memberCount,
}: {
  leagueId: string;
  joinCode: string;
  isOwner: boolean;
  entryFee: number;
  memberCount: number;
}) {
  const t = useTranslations("league");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [copied, setCopied] = useState(false);
  const [fee, setFee] = useState(String(entryFee));
  const [feeSaved, setFeeSaved] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const pot = (Number(fee) || 0) * memberCount;

  const saveFee = () => {
    setError("");
    setFeeSaved(false);
    startTransition(async () => {
      const res = await updateLeagueFee(leagueId, parseFloat(fee) || 0);
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      setFeeSaved(true);
      router.refresh();
    });
  };

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(joinCode);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* ignore */
    }
  };

  const run = (action: () => Promise<{ ok: true } | { error: string }>, confirmMsg: string) => {
    if (!window.confirm(confirmMsg)) return;
    setError("");
    startTransition(async () => {
      const res = await action();
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      router.push("/dashboard");
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      <div>
        <p className="text-sm text-muted mb-1">{t("inviteCode")}</p>
        <div className="flex items-center gap-2">
          <code className="text-2xl font-mono font-bold tracking-widest text-primary bg-primary/10 px-4 py-2 rounded-xl">
            {joinCode}
          </code>
          <button
            onClick={copy}
            className="text-sm px-4 py-2 rounded-full border border-border hover:bg-surface-hover transition-colors"
          >
            {copied ? t("copied") : t("copy")}
          </button>
        </div>
        <p className="text-xs text-muted mt-1.5">{t("inviteHint")}</p>
      </div>

      {/* Bote */}
      <div className="border-t border-border pt-4">
        <p className="text-sm text-muted mb-1">{t("pot")}</p>
        <p className="text-2xl font-bold text-secondary">
          {pot.toLocaleString("es-ES")} €
          <span className="text-sm font-normal text-muted ml-2">
            {(Number(fee) || 0).toLocaleString("es-ES")} € · {memberCount} {memberCount === 1 ? t("member") : t("members")}
          </span>
        </p>
        {isOwner && (
          <div className="flex items-center gap-2 mt-2">
            <div className="relative w-32">
              <input
                type="number"
                min={0}
                step="0.5"
                inputMode="decimal"
                value={fee}
                onChange={(e) => {
                  setFee(e.target.value);
                  if (feeSaved) setFeeSaved(false);
                }}
                className="w-full px-3 py-2 pr-7 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50"
              />
              <span className="absolute right-3 top-1/2 -translate-y-1/2 text-muted text-sm">€</span>
            </div>
            <button
              onClick={saveFee}
              disabled={isPending}
              className="text-sm bg-primary text-white px-4 py-2 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
            >
              {feeSaved ? `✓ ${t("saved")}` : isPending ? t("saving") : t("saveFee")}
            </button>
          </div>
        )}
        <p className="text-xs text-muted mt-1.5">{t("potHint")}</p>
      </div>

      <div className="flex flex-wrap gap-3 pt-2">
        {isOwner ? (
          <button
            onClick={() => run(() => deleteLeague(leagueId), t("confirmDelete"))}
            disabled={isPending}
            className="bg-red-500/10 text-red-600 border border-red-500/30 px-5 py-2 rounded-full text-sm font-medium hover:bg-red-500/20 transition-colors disabled:opacity-50"
          >
            {t("delete")}
          </button>
        ) : (
          <button
            onClick={() => run(() => leaveLeague(leagueId), t("confirmLeave"))}
            disabled={isPending}
            className="bg-red-500/10 text-red-600 border border-red-500/30 px-5 py-2 rounded-full text-sm font-medium hover:bg-red-500/20 transition-colors disabled:opacity-50"
          >
            {t("leave")}
          </button>
        )}
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
    </div>
  );
}
