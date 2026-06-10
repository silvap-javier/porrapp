"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { joinLeague } from "@/lib/leagues-actions";

export default function JoinLeagueForm() {
  const t = useTranslations("leaguesJoin");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    startTransition(async () => {
      const result = await joinLeague(code);
      if ("error" in result) {
        setError(tErr(result.error));
        return;
      }
      router.push(`/leagues/${result.leagueId}`);
      router.refresh();
    });
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col sm:flex-row gap-2">
      <input
        type="text"
        value={code}
        onChange={(e) => setCode(e.target.value.toUpperCase())}
        maxLength={8}
        className="flex-1 px-4 py-2.5 rounded-xl border border-border bg-surface uppercase tracking-widest font-mono focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary transition-colors"
        placeholder={t("placeholder")}
      />
      <button
        type="submit"
        disabled={isPending || !code.trim()}
        className="bg-secondary text-foreground px-6 py-2.5 rounded-full font-medium hover:brightness-95 transition-all disabled:opacity-50"
      >
        {isPending ? t("joining") : t("join")}
      </button>
      {error && <span className="text-sm text-red-600 self-center">{error}</span>}
    </form>
  );
}
