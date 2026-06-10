import { createClient } from "@/lib/supabase/server";
import { NextResponse } from "next/server";

function getBaseUrl(request: Request): string {
  const appUrl = process.env.NEXT_PUBLIC_APP_URL;
  if (appUrl) return appUrl;

  const forwardedHost = request.headers.get("x-forwarded-host");
  if (forwardedHost) return `https://${forwardedHost}`;

  return new URL(request.url).origin;
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const baseUrl = getBaseUrl(request);
  const code = searchParams.get("code");
  const next = searchParams.get("next") ?? "/dashboard";

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${baseUrl}${next}`);
    }
  }

  return NextResponse.redirect(`${baseUrl}/login?error=auth_callback_failed`);
}
