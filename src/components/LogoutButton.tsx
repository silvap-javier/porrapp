"use client";

import { useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { createClient } from "@/lib/supabase/client";

export default function LogoutButton() {
  const t = useTranslations("settings");
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const handleLogout = () => {
    startTransition(async () => {
      const supabase = createClient();
      await supabase.auth.signOut();
      router.push("/login");
      router.refresh();
    });
  };

  return (
    <button
      type="button"
      onClick={handleLogout}
      disabled={isPending}
      className="bg-red-500/10 text-red-600 border border-red-500/30 px-5 py-2 rounded-full text-sm font-medium hover:bg-red-500/20 transition-colors disabled:opacity-50"
    >
      {t("logout")}
    </button>
  );
}
