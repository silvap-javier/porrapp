"use client";

import { useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { getNotifications, markNotificationsSeen, type Notif } from "@/lib/notifications-actions";

const HREF: Record<Notif["type"], string> = {
  pending: "/matches",
  mentions: "/dashboard",
  results: "/resultados",
  members: "/dashboard",
};

export default function NotificationBell() {
  const t = useTranslations("notif");
  const [items, setItems] = useState<Notif[]>([]);
  const [total, setTotal] = useState(0);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const load = async () => {
    const res = await getNotifications();
    setItems(res.items);
    setTotal(res.total);
  };

  useEffect(() => {
    let active = true;
    const run = async () => {
      const res = await getNotifications();
      if (active) {
        setItems(res.items);
        setTotal(res.total);
      }
    };
    run();
    const id = setInterval(run, 60000);
    return () => {
      active = false;
      clearInterval(id);
    };
  }, []);

  // Cerrar al hacer clic fuera
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  const toggle = async () => {
    const next = !open;
    setOpen(next);
    if (next && items.some((i) => i.type !== "pending")) {
      await markNotificationsSeen();
      // Recalcula: deja solo "pending" (lo no-basado-en-tiempo)
      load();
    }
  };

  return (
    <div ref={ref} className="relative">
      <button
        onClick={toggle}
        className="relative w-8 h-8 flex items-center justify-center text-lg text-muted hover:text-foreground transition-colors"
        aria-label={t("title")}
      >
        🔔
        {total > 0 && (
          <span className="absolute -top-0.5 -right-0.5 min-w-4 h-4 px-1 rounded-full bg-accent text-white text-[10px] font-bold flex items-center justify-center">
            {total > 9 ? "9+" : total}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 mt-2 w-64 bg-surface border border-border rounded-2xl shadow-[var(--shadow-warm-lg)] overflow-hidden z-50">
          <div className="px-4 py-2.5 border-b border-border text-sm font-semibold text-foreground">
            {t("title")}
          </div>
          {items.length === 0 ? (
            <p className="px-4 py-5 text-sm text-muted text-center">{t("empty")}</p>
          ) : (
            <ul>
              {items.map((i) => (
                <li key={i.type}>
                  <Link
                    href={HREF[i.type]}
                    onClick={() => setOpen(false)}
                    className="flex items-center gap-3 px-4 py-3 hover:bg-surface-hover transition-colors border-b border-border/60 last:border-0"
                  >
                    <span className="text-lg">{t(`${i.type}Icon`)}</span>
                    <span className="flex-1 text-sm text-foreground">{t(i.type, { count: i.count })}</span>
                    <span className="text-muted">›</span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
