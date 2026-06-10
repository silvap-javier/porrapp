"use client";

import { useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";

type Props = {
  action: () => Promise<{ ok: true } | { error: string }>;
  confirmMessage: string;
  label: string;
  pendingLabel?: string;
  variant?: "danger" | "ghost";
  redirectTo?: string;
};

export default function ConfirmActionButton({
  action,
  confirmMessage,
  label,
  pendingLabel,
  variant = "danger",
  redirectTo,
}: Props) {
  const tErr = useTranslations("errors");
  const router = useRouter();
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const handleClick = () => {
    if (!window.confirm(confirmMessage)) return;
    setError("");
    startTransition(async () => {
      const result = await action();
      if ("error" in result) {
        setError(tErr(result.error));
        return;
      }
      if (redirectTo) {
        router.push(redirectTo);
      }
      router.refresh();
    });
  };

  const baseClasses =
    "text-sm font-medium px-4 py-2 rounded-full transition-colors disabled:opacity-50 disabled:cursor-not-allowed";
  const variantClasses =
    variant === "danger"
      ? "bg-red-500/10 text-red-600 hover:bg-red-500/20 border border-red-500/30"
      : "text-muted hover:text-foreground hover:bg-surface-hover";

  return (
    <div className="flex flex-col items-start gap-1.5">
      <button
        type="button"
        onClick={handleClick}
        disabled={isPending}
        className={`${baseClasses} ${variantClasses}`}
      >
        {isPending && pendingLabel ? pendingLabel : label}
      </button>
      {error && <p className="text-xs text-red-600">{error}</p>}
    </div>
  );
}
