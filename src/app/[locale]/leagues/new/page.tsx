import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import NewLeagueForm from "@/components/NewLeagueForm";

export default async function NewLeaguePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const t = await getTranslations("leaguesNew");

  return (
    <div className="max-w-md mx-auto px-4 py-8 space-y-6">
      <h1 className="text-2xl font-bold text-foreground font-display">{t("title")}</h1>
      <p className="text-sm text-muted">{t("subtitle")}</p>
      <NewLeagueForm />
    </div>
  );
}
