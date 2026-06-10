import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "@/i18n/routing";

const intlMiddleware = createMiddleware(routing);

// Paths that don't require authentication (relative to locale)
const publicPaths = [
  "/login",
  "/register",
  "/auth/callback",
  "/auth/confirm",
  "/forgot-password",
  "/reset-password",
];

// Authenticated users on these paths should NOT be redirected to /dashboard
const noRedirectWhenAuth = ["/reset-password"];

function getPathWithoutLocale(pathname: string): string {
  const localePattern = /^\/(es)(\/|$)/;
  return pathname.replace(localePattern, "/");
}

export async function proxy(request: NextRequest) {
  const pathname = request.nextUrl.pathname;

  // Skip static files
  if (pathname.match(/\.(?:svg|png|jpg|jpeg|gif|webp|json|js|ico|css|xml|txt)$/)) {
    return NextResponse.next();
  }

  // Skip i18n for API routes, auth routes, and SEO files
  if (
    pathname.startsWith("/api/") ||
    pathname.startsWith("/auth/") ||
    pathname === "/sitemap.xml" ||
    pathname === "/robots.txt"
  ) {
    return NextResponse.next();
  }

  const response = intlMiddleware(request);

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value)
          );
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const pathWithoutLocale = getPathWithoutLocale(pathname);
  const isHomePage = pathWithoutLocale === "/" || pathname === "/";
  const isPublicPath =
    isHomePage ||
    publicPaths.some((path) => pathWithoutLocale.startsWith(path));

  if (!user && !isPublicPath) {
    const url = request.nextUrl.clone();
    url.pathname = `/login`;
    return NextResponse.redirect(url);
  }

  const shouldRedirect =
    isPublicPath &&
    !isHomePage &&
    !noRedirectWhenAuth.some((p) => pathWithoutLocale.startsWith(p));

  if (user && shouldRedirect) {
    const url = request.nextUrl.clone();
    url.pathname = `/dashboard`;
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp|json|js|ico|css|xml|txt)$).*)",
  ],
};
