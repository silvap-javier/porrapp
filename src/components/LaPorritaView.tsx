"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { savePrediction, getMatchPredictions, type RivalPrediction } from "@/lib/prediction-actions";
import { isMatchOpen, scoreMatch } from "@/lib/scoring";
import { formatDay } from "@/lib/format";
import { LOCK_MINUTES, STAGE_LABELS, type Stage } from "@/lib/types";

/** Etiqueta "cierra en Xh Ym" para un partido abierto cuyo cierre es inminente (<24 h). */
function lockLabel(kickoffAt: string, now: number): string | null {
  const lockAt = new Date(kickoffAt).getTime() - LOCK_MINUTES * 60 * 1000;
  const ms = lockAt - now;
  if (ms <= 0 || ms > 24 * 60 * 60 * 1000) return null;
  const mins = Math.floor(ms / 60000);
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h > 0) return `cierra en ${h}h ${m}m`;
  if (m > 0) return `cierra en ${m} min`;
  return "cierra en <1 min";
}

type Side = { flag: string; name: string };

export type LMatch = {
  id: string;
  matchNumber: number;
  stage: Stage;
  group: string | null;
  jornada: number;
  kickoffAt: string;
  status: "scheduled" | "finished";
  homeScore: number | null;
  awayScore: number | null;
  home: Side;
  away: Side;
  predHome: number | null;
  predAway: number | null;
};

type Pred = { h: number; a: number };
const KO_ORDER: Stage[] = ["r32", "r16", "qf", "sf", "third", "final"];

export default function LaPorritaView({
  matches,
  teamsByGroup,
}: {
  matches: LMatch[];
  teamsByGroup: Record<string, Side[]>;
}) {
  const t = useTranslations("porrita");

  const [preds, setPreds] = useState<Record<string, Pred>>(() => {
    const init: Record<string, Pred> = {};
    for (const m of matches) {
      if (m.predHome !== null && m.predAway !== null) init[m.id] = { h: m.predHome, a: m.predAway };
    }
    return init;
  });
  const [expanded, setExpanded] = useState<Set<string>>(new Set(["A"]));
  const [active, setActive] = useState<LMatch | null>(null);
  const [view, setView] = useState<"group" | "date">("group");

  // Reloj que avanza para la cuenta atrás de cierre (sin Date.now en render).
  const [now, setNow] = useState(0);
  useEffect(() => {
    const tick = () => setNow(new Date().getTime());
    const t0 = setTimeout(tick, 0);
    const id = setInterval(tick, 30000);
    return () => {
      clearTimeout(t0);
      clearInterval(id);
    };
  }, []);

  // Agrupa TODOS los partidos por día (orden cronológico) para la vista "Por fecha".
  const days = useMemo(() => {
    const sorted = [...matches].sort(
      (a, b) => new Date(a.kickoffAt).getTime() - new Date(b.kickoffAt).getTime()
    );
    const out: { key: string; label: string; matches: LMatch[] }[] = [];
    for (const m of sorted) {
      const key = new Date(m.kickoffAt).toLocaleDateString("es-ES");
      const last = out[out.length - 1];
      if (last && last.key === key) last.matches.push(m);
      else {
        const label = formatDay(m.kickoffAt);
        out.push({ key, label: label.charAt(0).toUpperCase() + label.slice(1), matches: [m] });
      }
    }
    return out;
  }, [matches]);

  const total = matches.length;
  const predCount = matches.filter((m) => preds[m.id]).length;

  const groups = useMemo(
    () => Array.from(new Set(matches.filter((m) => m.group).map((m) => m.group as string))).sort(),
    [matches]
  );
  const koStages = useMemo(
    () => KO_ORDER.filter((s) => matches.some((m) => m.stage === s)),
    [matches]
  );

  const toggle = (key: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const pendingCount = (ms: LMatch[]) =>
    ms.filter((m) => isMatchOpen(m.kickoffAt, m.status) && !preds[m.id]).length;

  const onSaved = (id: string, h: number, a: number) => {
    setPreds((p) => ({ ...p, [id]: { h, a } }));
    setActive(null);
  };

  const pct = total ? Math.round((predCount / total) * 100) : 0;

  return (
    <div className="space-y-3">
      {/* Resumen */}
      <div className="bg-surface border border-border rounded-2xl p-4 shadow-[var(--shadow-warm)]">
        <div className="flex items-center justify-between text-sm">
          <span className="flex items-center gap-2 font-medium text-foreground">
            ⚽ {predCount} / {total} {t("predictions")}
          </span>
          <span className="text-muted">{pct}%</span>
        </div>
        <div className="mt-2 h-1.5 rounded-full bg-surface-hover overflow-hidden">
          <div className="h-full bg-primary transition-all" style={{ width: `${pct}%` }} />
        </div>
      </div>

      {/* Conmutador de vista */}
      <div className="flex gap-1.5 bg-surface border border-border rounded-full p-1">
        {(["group", "date"] as const).map((v) => (
          <button
            key={v}
            onClick={() => setView(v)}
            className={`flex-1 text-sm py-1.5 rounded-full font-medium transition-colors ${
              view === v ? "bg-primary text-white" : "text-muted hover:text-foreground"
            }`}
          >
            {t(v === "group" ? "byGroup" : "byDate")}
          </button>
        ))}
      </div>

      {/* Vista por fecha */}
      {view === "date" &&
        days.map((d) => {
          const dayPending = pendingCount(d.matches);
          const dayDone = d.matches.filter((m) => preds[m.id]).length;
          return (
            <div key={d.key} className="rounded-2xl overflow-hidden border border-border">
              <div className="flex items-center justify-between bg-gradient-to-r from-primary to-primary-dark px-4 py-2.5">
                <span className="font-bold text-white">{d.label}</span>
                <span className="flex items-center gap-2">
                  {dayPending > 0 && (
                    <span className="text-[11px] font-semibold text-white/90 bg-white/15 px-2 py-0.5 rounded-full">
                      {dayPending} {t("pending")}
                    </span>
                  )}
                  <span className="text-xs font-semibold text-white/90 bg-white/15 px-2 py-0.5 rounded-full">
                    ✎ {dayDone}/{d.matches.length}
                  </span>
                </span>
              </div>
              <div className="bg-surface">
                {d.matches.map((m) => (
                  <MatchRow key={m.id} m={m} pred={preds[m.id]} now={now} onOpen={setActive} />
                ))}
              </div>
            </div>
          );
        })}

      {/* Vista por grupo */}
      {view === "group" && groups.map((g) => {
        const gm = matches.filter((m) => m.group === g);
        const done = gm.filter((m) => preds[m.id]).length;
        const jornadas = Array.from(new Set(gm.map((m) => m.jornada))).sort((a, b) => a - b);
        const key = `g-${g}`;
        const isOpen = expanded.has(g) || expanded.has(key);
        const pend = pendingCount(gm);
        return (
          <div key={g} className="rounded-2xl overflow-hidden border border-border">
            {/* Cabecera verde */}
            <div className="flex items-center justify-between bg-gradient-to-r from-primary to-primary-dark px-4 py-2.5">
              <span className="font-bold text-white">{t("group")} {g}</span>
              <span className="text-xs font-semibold text-white/90 bg-white/15 px-2 py-0.5 rounded-full">
                ✎ {done}/{gm.length}
              </span>
            </div>

            {/* Equipos */}
            <ul className="bg-surface divide-y divide-border">
              {(teamsByGroup[g] ?? []).map((tm, i) => (
                <li key={i} className="flex items-center gap-3 px-4 py-2">
                  <span className="text-xs text-muted w-3">{i + 1}</span>
                  <span className="text-lg">{tm.flag}</span>
                  <span className="text-sm text-foreground">{tm.name}</span>
                </li>
              ))}
            </ul>

            {/* Partidos plegable */}
            <button
              onClick={() => toggle(g)}
              className="w-full flex items-center justify-between bg-surface border-t border-border px-4 py-2.5"
            >
              <span className="text-sm font-medium text-foreground">{t("matchesLabel")}</span>
              <span className="flex items-center gap-2">
                {pend > 0 && (
                  <span className="text-[11px] font-semibold text-secondary bg-secondary/15 px-2 py-0.5 rounded-full">
                    {pend} {t("pending")}
                  </span>
                )}
                <span className="text-muted">{isOpen ? "▲" : "▼"}</span>
              </span>
            </button>

            {isOpen && (
              <div className="bg-background/40">
                {jornadas.map((j) => (
                  <div key={j}>
                    <div className="px-4 py-1.5 text-xs font-medium text-muted bg-surface-hover/50">
                      {t("matchday")} {j}
                    </div>
                    {gm
                      .filter((m) => m.jornada === j)
                      .map((m) => (
                        <MatchRow key={m.id} m={m} pred={preds[m.id]} now={now} onOpen={setActive} />
                      ))}
                  </div>
                ))}
              </div>
            )}
          </div>
        );
      })}

      {/* Eliminatorias */}
      {view === "group" && koStages.map((s) => {
        const sm = matches.filter((m) => m.stage === s);
        const done = sm.filter((m) => preds[m.id]).length;
        const isOpen = expanded.has(s);
        const pend = pendingCount(sm);
        return (
          <div key={s} className="rounded-2xl overflow-hidden border border-border">
            <button
              onClick={() => toggle(s)}
              className="w-full flex items-center justify-between bg-gradient-to-r from-secondary/80 to-secondary px-4 py-2.5"
            >
              <span className="font-bold text-foreground">{STAGE_LABELS[s]}</span>
              <span className="flex items-center gap-2">
                <span className="text-xs font-semibold text-foreground/80 bg-black/10 px-2 py-0.5 rounded-full">
                  ✎ {done}/{sm.length}
                </span>
                <span className="text-foreground/70">{isOpen ? "▲" : "▼"}</span>
              </span>
            </button>
            {isOpen && (
              <div className="bg-surface">
                {pend > 0 && (
                  <div className="px-4 pt-2 text-[11px] text-secondary">{pend} {t("pending")}</div>
                )}
                {sm.map((m) => (
                  <MatchRow key={m.id} m={m} pred={preds[m.id]} now={now} onOpen={setActive} />
                ))}
              </div>
            )}
          </div>
        );
      })}

      {active && (
        <PredictionSheet
          match={active}
          initial={preds[active.id]}
          now={now}
          onClose={() => setActive(null)}
          onSaved={onSaved}
        />
      )}
    </div>
  );
}

function MatchRow({
  m,
  pred,
  now,
  onOpen,
}: {
  m: LMatch;
  pred?: Pred;
  now: number;
  onOpen: (m: LMatch) => void;
}) {
  const open = isMatchOpen(m.kickoffAt, m.status);
  const finished = m.status === "finished" && m.homeScore !== null && m.awayScore !== null;
  const points = finished && pred ? scoreMatch(pred.h, pred.a, m.homeScore!, m.awayScore!) : null;
  const closing = open && now ? lockLabel(m.kickoffAt, now) : null;

  return (
    <button
      onClick={() => onOpen(m)}
      disabled={!open && !finished && !pred}
      className="w-full flex items-center gap-2 px-3 py-2.5 border-t border-border/60 disabled:opacity-60 active:bg-surface-hover transition-colors"
    >
      <span className="text-[11px] text-muted w-7 flex-shrink-0 text-left">
        M{m.matchNumber}
        {closing && (
          <span className="block text-[9px] text-accent font-medium leading-tight">{closing}</span>
        )}
      </span>

      <span className="flex-1 flex items-center justify-end gap-1.5 min-w-0">
        <span className="text-sm text-foreground truncate text-right">{m.home.name}</span>
        <span className="text-base flex-shrink-0">{m.home.flag}</span>
      </span>

      <span className="flex-shrink-0">
        {pred ? (
          <span className="text-sm font-bold tabular-nums text-foreground bg-surface-hover px-2.5 py-1 rounded-lg">
            {pred.h}–{pred.a}
          </span>
        ) : open ? (
          <span className="text-xs text-primary border border-primary/40 px-2.5 py-1 rounded-lg">
            ✎ vs
          </span>
        ) : (
          <span className="text-xs text-muted px-2.5 py-1">vs</span>
        )}
      </span>

      <span className="flex-1 flex items-center gap-1.5 min-w-0">
        <span className="text-base flex-shrink-0">{m.away.flag}</span>
        <span className="text-sm text-foreground truncate">{m.away.name}</span>
      </span>

      <span className="w-10 flex-shrink-0 text-right">
        {finished ? (
          <span className="text-[11px] font-semibold text-foreground">
            {m.homeScore}-{m.awayScore}
            {points !== null && (
              <span className={`block ${points > 0 ? "text-primary" : "text-muted"}`}>+{points}</span>
            )}
          </span>
        ) : pred ? (
          <span className="inline-block w-2.5 h-2.5 rounded-full bg-primary" />
        ) : open ? (
          <span className="inline-block w-2.5 h-2.5 rounded-full ring-2 ring-accent" />
        ) : (
          <span className="inline-block w-2.5 h-2.5 rounded-full bg-border" />
        )}
      </span>
    </button>
  );
}

const QUICK: [number, number][] = [
  [1, 0], [0, 0], [0, 1],
  [2, 0], [1, 1], [0, 2],
  [2, 1], [2, 2], [1, 2],
  [3, 0], [3, 3], [0, 3],
  [3, 1], [4, 4], [1, 3],
];

function PredictionSheet({
  match,
  initial,
  now,
  onClose,
  onSaved,
}: {
  match: LMatch;
  initial?: Pred;
  now: number;
  onClose: () => void;
  onSaved: (id: string, h: number, a: number) => void;
}) {
  const t = useTranslations("porrita");
  const tErr = useTranslations("errors");
  const router = useRouter();
  const open = isMatchOpen(match.kickoffAt, match.status);
  const closing = open && now ? lockLabel(match.kickoffAt, now) : null;
  const finished = match.status === "finished" && match.homeScore !== null && match.awayScore !== null;
  const [h, setH] = useState(initial?.h?.toString() ?? "");
  const [a, setA] = useState(initial?.a?.toString() ?? "");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  // Pronósticos de la peña (solo cuando el partido ya está cerrado).
  const [rivals, setRivals] = useState<RivalPrediction[] | null>(null);
  useEffect(() => {
    if (open) return;
    let active = true;
    getMatchPredictions(match.id).then((rows) => {
      if (active) setRivals(rows);
    });
    return () => {
      active = false;
    };
  }, [open, match.id]);

  const save = () => {
    setError("");
    startTransition(async () => {
      const res = await savePrediction({
        matchId: match.id,
        homeScore: parseInt(h || "0", 10),
        awayScore: parseInt(a || "0", 10),
      });
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      onSaved(match.id, parseInt(h, 10), parseInt(a, 10));
      router.refresh();
    });
  };

  const canSave = open && h !== "" && a !== "" && !isPending;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center" onClick={onClose}>
      <div className="absolute inset-0 bg-black/50" />
      <div
        onClick={(e) => e.stopPropagation()}
        className="relative w-full max-w-2xl bg-surface rounded-t-3xl p-4 pb-safe shadow-2xl max-h-[88vh] overflow-y-auto"
      >
        <div className="w-10 h-1 rounded-full bg-border mx-auto mb-3" />

        <div className="flex items-center justify-between mb-4">
          <button onClick={onClose} className="text-sm text-muted hover:text-foreground">
            {t("cancel")}
          </button>
          <span className="text-sm font-semibold text-foreground flex flex-col items-center leading-tight">
            {t("prediction")} M{match.matchNumber}
            {closing && <span className="text-[10px] font-medium text-accent">{closing}</span>}
          </span>
          <button
            onClick={save}
            disabled={!canSave}
            className="text-sm font-semibold text-primary disabled:opacity-40"
          >
            {isPending ? t("saving") : t("save")}
          </button>
        </div>

        {/* Equipos + marcador manual */}
        <div className="flex items-center justify-between gap-2 mb-4">
          <div className="flex-1 text-center min-w-0">
            <div className="text-4xl">{match.home.flag}</div>
            <div className="text-xs font-medium text-foreground mt-1 truncate">{match.home.name}</div>
          </div>
          <div className="flex items-center gap-2 flex-shrink-0">
            <input
              type="number" min={0} max={99} inputMode="numeric" value={h}
              disabled={!open || isPending}
              onChange={(e) => setH(e.target.value)}
              className="w-14 h-12 text-center text-xl rounded-xl border border-border bg-background disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
              placeholder="-"
            />
            <span className="text-muted">-</span>
            <input
              type="number" min={0} max={99} inputMode="numeric" value={a}
              disabled={!open || isPending}
              onChange={(e) => setA(e.target.value)}
              className="w-14 h-12 text-center text-xl rounded-xl border border-border bg-background disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50"
              placeholder="-"
            />
          </div>
          <div className="flex-1 text-center min-w-0">
            <div className="text-4xl">{match.away.flag}</div>
            <div className="text-xs font-medium text-foreground mt-1 truncate">{match.away.name}</div>
          </div>
        </div>

        {!open ? (
          <p className="text-center text-sm text-muted py-4">🔒 {t("locked")}</p>
        ) : (
          <>
            <div className="grid grid-cols-3 gap-2 text-[11px] font-semibold mb-1.5">
              <span className="text-center text-primary">{t("homeWin")}</span>
              <span className="text-center text-muted">{t("draw")}</span>
              <span className="text-center text-blue-600">{t("awayWin")}</span>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {QUICK.map(([qh, qa]) => {
                const selected = h === String(qh) && a === String(qa);
                const kind = qh > qa ? "home" : qh === qa ? "draw" : "away";
                const base = "py-2.5 rounded-xl text-sm font-semibold border transition-colors";
                const styles =
                  kind === "home"
                    ? selected ? "bg-primary text-white border-primary" : "border-primary/40 text-primary hover:bg-primary/10"
                    : kind === "draw"
                    ? selected ? "bg-muted text-white border-muted" : "border-border text-muted hover:bg-surface-hover"
                    : selected ? "bg-blue-600 text-white border-blue-600" : "border-blue-500/40 text-blue-600 hover:bg-blue-500/10";
                return (
                  <button
                    key={`${qh}-${qa}`}
                    onClick={() => { setH(String(qh)); setA(String(qa)); }}
                    className={`${base} ${styles}`}
                  >
                    {qh}-{qa}
                  </button>
                );
              })}
            </div>
          </>
        )}

        {error && <p className="text-sm text-red-600 mt-3 text-center">{error}</p>}

        {/* Pronósticos de la peña (partido cerrado) */}
        {!open && rivals !== null && (
          <div className="mt-5 border-t border-border pt-4">
            <h3 className="text-sm font-semibold text-foreground mb-2">{t("rivals")}</h3>
            {rivals.length === 0 ? (
              <p className="text-sm text-muted">{t("noRivals")}</p>
            ) : (
              <ul className="space-y-1.5">
                {[...rivals]
                  .map((r) => ({
                    ...r,
                    pts: finished ? scoreMatch(r.home, r.away, match.homeScore!, match.awayScore!) : null,
                  }))
                  .sort((x, y) => (y.pts ?? 0) - (x.pts ?? 0) || x.name.localeCompare(y.name))
                  .map((r) => (
                    <li
                      key={r.userId}
                      className="flex items-center gap-2 text-sm bg-background rounded-lg px-3 py-1.5"
                    >
                      <span className="flex-1 truncate text-foreground">{r.name}</span>
                      <span className="font-bold tabular-nums text-foreground">
                        {r.home}–{r.away}
                      </span>
                      {r.pts !== null && (
                        <span
                          className={`text-xs font-semibold w-8 text-right ${
                            r.pts > 0 ? "text-primary" : "text-muted"
                          }`}
                        >
                          +{r.pts}
                        </span>
                      )}
                    </li>
                  ))}
              </ul>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
