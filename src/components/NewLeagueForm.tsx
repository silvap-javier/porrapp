"use client";

import { useState, useTransition } from "react";
import { useRouter, Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { createLeague } from "@/lib/leagues-actions";

export default function NewLeagueForm() {
  const t = useTranslations("leaguesNew");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [name, setName] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    startTransition(async () => {
      const result = await createLeague(name);
      if ("error" in result) {
        setError(tErr(result.error));
        return;
      }
      router.push(`/leagues/${result.leagueId}`);
      router.refresh();
    });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      {error && (
        <div className="bg-red-500/10 text-red-600 text-sm p-3 rounded-lg border border-red-500/25">
          {error}
        </div>
      )}

      <div>
        <label htmlFor="name" className="block text-sm font-medium text-foreground mb-1">
          {t("name")}
        </label>
        <input
          id="name"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          maxLength={100}
          autoFocus
          className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary transition-colors"
          placeholder={t("namePlaceholder")}
        />
      </div>

      <div className="flex items-center gap-3 pt-2">
        <button
          type="submit"
          disabled={isPending || !name.trim()}
          className="bg-primary text-white px-6 py-2.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isPending ? t("creating") : t("create")}
        </button>
        <Link href="/dashboard" className="text-sm text-muted hover:text-foreground transition-colors">
          {t("cancel")}
        </Link>
      </div>
    </form>
  );
}
