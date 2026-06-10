import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";

export default function LandingPage() {
  const t = useTranslations("landing");

  return (
    <div className="max-w-5xl mx-auto px-4 py-16 sm:py-24">
      <section className="text-center">
        <div className="text-6xl mb-6">⚽🏆</div>
        <h1 className="text-4xl sm:text-5xl font-bold text-foreground font-display tracking-tight">
          {t("title")}
        </h1>
        <p className="text-muted mt-5 text-lg max-w-xl mx-auto leading-relaxed">
          {t("subtitle")}
        </p>

        <div className="mt-10 flex flex-col sm:flex-row items-center justify-center gap-3">
          <Link
            href="/register"
            className="inline-block bg-gradient-to-b from-primary to-primary-dark text-white px-8 py-3 rounded-full font-medium shadow-[var(--shadow-warm)] active:translate-y-0.5 transition-all"
          >
            {t("ctaPrimary")}
          </Link>
          <Link
            href="/login"
            className="inline-block text-foreground hover:text-primary px-6 py-3 transition-colors"
          >
            {t("ctaSecondary")}
          </Link>
        </div>
      </section>

      <section className="grid sm:grid-cols-3 gap-6 mt-20">
        <Feature emoji="🎯" title={t("feature1Title")} body={t("feature1Body")} />
        <Feature emoji="👥" title={t("feature2Title")} body={t("feature2Body")} />
        <Feature emoji="📊" title={t("feature3Title")} body={t("feature3Body")} />
      </section>
    </div>
  );
}

function Feature({ emoji, title, body }: { emoji: string; title: string; body: string }) {
  return (
    <div className="bg-surface rounded-2xl p-6 border border-border shadow-[var(--shadow-warm)]">
      <div className="text-3xl mb-3">{emoji}</div>
      <h3 className="font-semibold text-foreground mb-2">{title}</h3>
      <p className="text-sm text-muted leading-relaxed">{body}</p>
    </div>
  );
}
