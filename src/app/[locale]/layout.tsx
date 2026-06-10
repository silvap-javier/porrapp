import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Lora } from "next/font/google";
import { NextIntlClientProvider } from "next-intl";
import { getMessages } from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "@/i18n/routing";
import Navbar from "@/components/Navbar";
import ServiceWorkerRegister from "@/components/ServiceWorkerRegister";
import "../globals.css";

export const dynamic = "force-dynamic";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const lora = Lora({
  variable: "--font-lora",
  subsets: ["latin"],
  weight: ["500", "600", "700"],
  style: ["normal", "italic"],
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: "PorrApp – La porra del Mundial entre amigos",
    template: "%s | PorrApp",
  },
  description:
    "Pronostica los partidos del Mundial 2026, compite por aciertos en ligas privadas con tus amigos y mira quién manda en la tabla.",
  keywords: [
    "porra mundial",
    "prode mundial 2026",
    "pronósticos fútbol",
    "porra entre amigos",
    "quiniela mundial",
  ],
  manifest: "/manifest.json",
  icons: {
    icon: [{ url: "/icons/icon.svg", type: "image/svg+xml" }],
    apple: [{ url: "/icons/icon.svg" }],
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "PorrApp",
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#0f9d58" },
    { media: "(prefers-color-scheme: dark)", color: "#0e1512" },
  ],
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
};

type Props = {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
};

export default async function LocaleLayout({ children, params }: Props) {
  const { locale } = await params;

  if (!routing.locales.includes(locale as "es")) {
    notFound();
  }

  const messages = await getMessages();

  return (
    <html
      lang={locale}
      className={`${geistSans.variable} ${geistMono.variable} ${lora.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        {/* Theme bootstrap — must run before paint to avoid light/dark flash. */}
        <script
          suppressHydrationWarning
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var t=localStorage.getItem('theme');var d=t?t==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches;if(d)document.documentElement.classList.add('dark');}catch(e){}})();`,
          }}
        />
      </head>
      <body className="min-h-full flex flex-col">
        <NextIntlClientProvider messages={messages}>
          <ServiceWorkerRegister />
          <Navbar />
          <main className="flex-1">{children}</main>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
