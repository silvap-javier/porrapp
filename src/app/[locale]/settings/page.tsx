import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { createClient } from "@/lib/supabase/server";
import ProfileForm from "@/components/ProfileForm";
import LogoutButton from "@/components/LogoutButton";

export default async function SettingsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profile } = await supabase
    .from("profiles")
    .select("name, email")
    .eq("id", user.id)
    .maybeSingle();

  const t = await getTranslations("settings");

  return (
    <div className="max-w-xl mx-auto px-4 py-8 space-y-8">
      <h1 className="text-3xl font-bold text-foreground font-display">{t("title")}</h1>

      <section className="bg-surface border border-border rounded-2xl p-5 shadow-[var(--shadow-warm)]">
        <h2 className="font-semibold text-foreground mb-3">{t("profileSection")}</h2>
        <p className="text-sm text-muted mb-4">{profile?.email}</p>
        <ProfileForm initialName={profile?.name ?? ""} />
      </section>

      <section className="bg-surface border border-border rounded-2xl p-5 shadow-[var(--shadow-warm)]">
        <h2 className="font-semibold text-foreground mb-3">{t("dangerSection")}</h2>
        <LogoutButton />
      </section>
    </div>
  );
}
