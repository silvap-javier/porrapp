"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { savePushSubscription, deletePushSubscription } from "@/lib/push-actions";

const VAPID_PUBLIC = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? "";

function urlBase64ToUint8Array(base64: string): Uint8Array {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const b64 = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b64);
  const arr = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
  return arr;
}

type State = "loading" | "unsupported" | "off" | "on" | "denied" | "busy";

export default function PushToggle() {
  const t = useTranslations("push");
  const [state, setState] = useState<State>("loading");

  useEffect(() => {
    let active = true;
    const init = async () => {
      if (
        typeof window === "undefined" ||
        !("serviceWorker" in navigator) ||
        !("PushManager" in window) ||
        !VAPID_PUBLIC
      ) {
        if (active) setState("unsupported");
        return;
      }
      if (Notification.permission === "denied") {
        if (active) setState("denied");
        return;
      }
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (active) setState(sub ? "on" : "off");
    };
    init().catch(() => active && setState("unsupported"));
    return () => {
      active = false;
    };
  }, []);

  const enable = async () => {
    setState("busy");
    try {
      const perm = await Notification.requestPermission();
      if (perm !== "granted") {
        setState(perm === "denied" ? "denied" : "off");
        return;
      }
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC) as BufferSource,
      });
      const json = sub.toJSON() as { endpoint?: string; keys?: { p256dh?: string; auth?: string } };
      const res = await savePushSubscription({
        endpoint: json.endpoint ?? sub.endpoint,
        p256dh: json.keys?.p256dh ?? "",
        auth: json.keys?.auth ?? "",
      });
      setState("error" in res ? "off" : "on");
    } catch {
      setState("off");
    }
  };

  const disable = async () => {
    setState("busy");
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (sub) {
        await deletePushSubscription(sub.endpoint);
        await sub.unsubscribe();
      }
      setState("off");
    } catch {
      setState("on");
    }
  };

  if (state === "loading") return <p className="text-sm text-muted">{t("loading")}</p>;
  if (state === "unsupported") return <p className="text-sm text-muted">{t("unsupported")}</p>;
  if (state === "denied") return <p className="text-sm text-muted">{t("denied")}</p>;

  const on = state === "on";
  const busy = state === "busy";

  return (
    <div className="flex items-center justify-between gap-3">
      <p className="text-sm text-muted flex-1">{on ? t("onHint") : t("offHint")}</p>
      <button
        onClick={on ? disable : enable}
        disabled={busy}
        className={`px-4 py-2 rounded-full text-sm font-medium transition-colors disabled:opacity-50 ${
          on
            ? "bg-surface-hover border border-border text-foreground"
            : "bg-primary text-white hover:bg-primary-dark"
        }`}
      >
        {busy ? t("busy") : on ? t("disable") : t("enable")}
      </button>
    </div>
  );
}
