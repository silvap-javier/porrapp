"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { createClient } from "@/lib/supabase/client";

export default function ForgotPasswordPage() {
  const t = useTranslations("forgotPassword");
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    const supabase = createClient();
    await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset-password`,
    });
    setSent(true);
    setLoading(false);
  };

  return (
    <div className="flex flex-1 items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <div className="text-5xl mb-3">🔑</div>
          <h1 className="text-2xl font-bold text-foreground">{t("title")}</h1>
          <p className="text-muted text-sm mt-1">{t("subtitle")}</p>
        </div>

        {sent ? (
          <div className="bg-primary/10 border border-primary/30 text-foreground text-sm p-4 rounded-lg text-center">
            {t("sent")}
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4">
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
              placeholder="tu@email.com"
            />
            <button
              type="submit"
              disabled={loading}
              className="w-full bg-primary text-white py-2.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
            >
              {loading ? t("sending") : t("submit")}
            </button>
          </form>
        )}

        <p className="text-center text-sm text-muted mt-6">
          <Link href="/login" className="text-primary hover:text-primary-dark">
            {t("backToLogin")}
          </Link>
        </p>
      </div>
    </div>
  );
}
