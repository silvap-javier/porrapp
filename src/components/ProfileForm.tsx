"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { updateProfileName } from "@/lib/profile-actions";

export default function ProfileForm({ initialName }: { initialName: string }) {
  const t = useTranslations("settings");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [name, setName] = useState(initialName);
  const [status, setStatus] = useState<"idle" | "saved">("idle");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setStatus("idle");
    startTransition(async () => {
      const result = await updateProfileName(name);
      if ("error" in result) {
        setError(tErr(result.error));
        return;
      }
      setStatus("saved");
      router.refresh();
    });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div>
        <label htmlFor="name" className="block text-sm font-medium text-foreground mb-1">
          {t("nameLabel")}
        </label>
        <input
          id="name"
          type="text"
          value={name}
          onChange={(e) => {
            setName(e.target.value);
            if (status === "saved") setStatus("idle");
          }}
          required
          maxLength={100}
          className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
        />
      </div>
      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={isPending || !name.trim()}
          className="bg-primary text-white px-5 py-2 rounded-full text-sm font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
        >
          {isPending ? t("saving") : t("save")}
        </button>
        {status === "saved" && (
          <span className="text-sm text-primary">✓ {t("saved")}</span>
        )}
        {error && <span className="text-sm text-red-600">{error}</span>}
      </div>
    </form>
  );
}
