const CACHE_NAME = "porrapp-v2";
const STATIC_ASSETS = ["/", "/login", "/register", "/dashboard"];

// Install: cache static assets
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

// Activate: clean old caches
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

// Push: muestra la notificación recibida del servidor
self.addEventListener("push", (event) => {
  let data = { title: "PorrApp", body: "", url: "/dashboard", tag: undefined };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch {
    if (event.data) data.body = event.data.text();
  }
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/icons/icon.svg",
      badge: "/icons/icon.svg",
      tag: data.tag,
      data: { url: data.url || "/dashboard" },
    })
  );
});

// Click: enfoca una pestaña existente o abre la URL del aviso
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "/dashboard";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const client of list) {
        if ("focus" in client) {
          client.navigate(target);
          return client.focus();
        }
      }
      return self.clients.openWindow(target);
    })
  );
});

// Fetch: network first, fallback to cache
self.addEventListener("fetch", (event) => {
  const url = event.request.url;
  // Only cache same-origin http(s) GETs. Skip auth, Supabase, browser
  // extension URLs (chrome-extension://, moz-extension://...), data:, blob:, etc.
  if (
    event.request.method !== "GET" ||
    !url.startsWith("http") ||
    url.includes("/auth/") ||
    url.includes("supabase")
  ) {
    return;
  }

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => {
            cache.put(event.request, clone).catch(() => {});
          });
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
