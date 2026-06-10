const CACHE_NAME = "porrapp-v1";
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
