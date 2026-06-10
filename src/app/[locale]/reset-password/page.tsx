"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useRouter } from "@/i18n/navigation";
import { createClient } from "@/lib/supabase/client";

export default function ResetPasswordPage() {
  const t = useTranslations("resetPassword");
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [success, setSuccess] = useState(false);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setError(error.message);
      setLoading(false);
      return;
    }
    setSuccess(true);
    setLoading(false);
    setTimeout(() => router.push("/dashboard"), 1500);
  };

  return (
    <div className="flex flex-1 items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <div className="text-5xl mb-3">🔐</div>
          <h1 className="text-2xl font-bold text-foreground">{t("title")}</h1>
        </div>

        {success ? (
          <div className="bg-primary/10 border border-primary/30 text-foreground text-sm p-4 rounded-lg text-center">
            {t("success")}
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4">
            {error && (
              <div className="bg-red-500/10 text-red-600 text-sm p-3 rounded-lg border border-red-500/25">
                {error}
              </div>
            )}
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              minLength={6}
              className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
              placeholder={t("newPassword")}
            />
            <button
              type="submit"
              disabled={loading}
              className="w-full bg-primary text-white py-2.5 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-50"
            >
              {loading ? t("saving") : t("submit")}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
