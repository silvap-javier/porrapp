"use client";

import { Link, useRouter } from "@/i18n/navigation";
import { createClient } from "@/lib/supabase/client";
import { useEffect, useState } from "react";
import type { User } from "@supabase/supabase-js";
import { useTranslations } from "next-intl";

export default function Navbar() {
  const t = useTranslations("nav");
  const router = useRouter();
  const supabase = createClient();
  const [user, setUser] = useState<User | null>(null);

  useEffect(() => {
    supabase.auth.getUser().then(({ data: { user } }) => {
      setUser(user);
    });
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user ?? null);
    });
    return () => subscription.unsubscribe();
  }, [supabase.auth]);

  const handleLogout = async () => {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  };

  return (
    <nav className="bg-surface/95 backdrop-blur-xl shadow-[0_1px_12px_rgba(0,0,0,0.04)] sticky top-0 z-50">
      <div className="max-w-5xl mx-auto px-4 h-14 flex items-center justify-between">
        <Link href={user ? "/dashboard" : "/"} className="flex items-center gap-2 flex-shrink-0">
          <span className="text-2xl">⚽</span>
          <span className="text-lg font-bold text-foreground tracking-tight font-display">
            Porr<span className="text-primary italic">App</span>
          </span>
        </Link>

        {user ? (
          <div className="flex items-center gap-3 sm:gap-4">
            <Link
              href="/matches"
              className="hidden sm:block text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("matches")}
            </Link>
            <Link
              href="/picks"
              className="hidden sm:block text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("picks")}
            </Link>
            <Link
              href="/results"
              className="hidden sm:block text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("results")}
            </Link>
            <Link
              href="/dashboard"
              className="hidden sm:block text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("leagues")}
            </Link>
            <button
              onClick={handleLogout}
              className="hidden sm:block text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("logout")}
            </button>
            <Link
              href="/settings"
              className="w-8 h-8 rounded-full bg-primary/15 flex items-center justify-center text-sm font-semibold text-primary-dark hover:bg-primary/25 transition-colors flex-shrink-0"
              title={t("settings")}
            >
              {user.email?.charAt(0).toUpperCase()}
            </Link>
          </div>
        ) : (
          <div className="flex items-center gap-3">
            <Link
              href="/login"
              className="text-sm text-muted hover:text-foreground transition-colors"
            >
              {t("login")}
            </Link>
            <Link
              href="/register"
              className="text-sm bg-gradient-to-b from-primary to-primary-dark text-white px-5 py-2 rounded-full font-medium shadow-[var(--shadow-warm)] active:shadow-none active:translate-y-0.5 transition-all"
            >
              {t("register")}
            </Link>
          </div>
        )}
      </div>
    </nav>
  );
}
