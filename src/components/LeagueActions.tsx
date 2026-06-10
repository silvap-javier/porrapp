"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { leaveLeague, deleteLeague } from "@/lib/leagues-actions";

export default function LeagueActions({
  leagueId,
  joinCode,
  isOwner,
}: {
  leagueId: string;
  joinCode: string;
  isOwner: boolean;
}) {
  const t = useTranslations("league");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

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
