# ⚽🏆 PorrApp

Webapp (PWA) para jugar la **porra/prode del Mundial 2026** entre amigos.
Pronostica el marcador de cada partido, haz tus picks de torneo (campeón,
subcampeón, goleador) y compite por aciertos en ligas privadas.

Construida con Next.js 16 + Supabase, en español e instalable como app.

---

## ✨ Funcionalidades

- **Pronósticos por partido**: marcador exacto de los 104 partidos. Cierran
  60 minutos antes de cada pitido inicial.
- **Macro picks de torneo**: campeón, subcampeón y goleador. Se cierran al
  arrancar el Mundial.
- **Ligas privadas**: crea una liga, comparte el código y compite con tus amigos.
  Tu pronóstico es global: vale en todas las ligas en las que juegas.
- **Tabla en vivo**: ranking por puntos acumulados, con desglose de aciertos.
- **Panel de resultados colaborativo**: cualquier usuario puede cargar o corregir
  el resultado de un partido. Cada cambio queda registrado (quién y cuándo) en un
  **log de auditoría** para mantener la transparencia.
- **PWA** instalable en el móvil, en español.

### Puntuación

| Acierto | Puntos |
|---------|--------|
| Marcador exacto | **3 + 1 = 4** (bonus exacto + resultado) |
| Solo resultado (1X2) | **1** |
| Campeón | 10 |
| Subcampeón | 5 |
| Goleador | 5 |

El esquema de partidos se guarda como configuración por liga (`leagues.scoring`)
para poder flexibilizarlo más adelante.

---

## 🧱 Stack

| Capa | Tecnología |
|------|-----------|
| Frontend | Next.js 16 (App Router) · TypeScript · Tailwind CSS v4 |
| Backend / DB / Auth | Supabase (Postgres + RLS) |
| i18n | next-intl (es) |
| PWA | manifest + service worker |
| Deploy | DigitalOcean App Platform (`.do/app.yaml`) |

---

## 🚀 Puesta en marcha

```bash
cp .env.local.example .env.local   # rellena con tu proyecto Supabase
npm install
npm run dev
```

### Base de datos

Aplica las migraciones de `supabase/migrations/` en orden (vía el SQL Editor de
Supabase o la CLI). La última (`006_seed_worldcup2026.sql`) carga 48 selecciones
en 12 grupos y los 104 partidos.

> ⚠️ El reparto de grupos y los horarios del seed son una **plantilla de
> desarrollo**. Como cualquier usuario puede corregir equipos, cruces y
> resultados desde `/resultados`, se ajusta en vivo contra el calendario oficial
> FIFA.

---

## 🗂️ Estructura

- `src/app/[locale]/` — páginas: `dashboard`, `leagues`, `matches`, `results`,
  `picks`, `settings` + auth.
- `src/lib/*-actions.ts` — Server Actions (ligas, pronósticos, picks, resultados).
- `src/lib/scoring.ts` — reglas de puntos (espejo TS de las funciones SQL).
- `supabase/migrations/` — esquema + RLS + funciones de ranking + seed.
