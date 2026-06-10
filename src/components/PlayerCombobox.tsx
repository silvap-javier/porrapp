"use client";

import { useEffect, useMemo, useRef, useState } from "react";
// nota: el valor inicial se siembra en useState; no se re-sincroniza desde props
// (tras guardar, el texto vive en el estado del propio combobox).
import type { FlatPlayer } from "@/lib/group-players";

/**
 * Buscador de jugador con autocompletado sobre toda la lista de selecciones.
 * Guarda el NOMBRE del jugador (texto) — el scoring del goleador compara por nombre.
 * Permite también texto libre por si el jugador no estuviera en la lista.
 */
export default function PlayerCombobox({
  players,
  value,
  onChange,
  disabled = false,
  placeholder,
}: {
  players: FlatPlayer[];
  value: string;
  onChange: (name: string) => void;
  disabled?: boolean;
  placeholder?: string;
}) {
  const [query, setQuery] = useState(value);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // Cerrar al hacer clic fuera (capturando el texto escrito).
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
        onChange(query.trim());
      }
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open, query, onChange]);

  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return players.slice(0, 30);
    const out: FlatPlayer[] = [];
    for (const p of players) {
      if (p.name.toLowerCase().includes(q) || p.team.toLowerCase().includes(q)) {
        out.push(p);
        if (out.length >= 30) break;
      }
    }
    return out;
  }, [players, query]);

  const pick = (name: string) => {
    setQuery(name);
    onChange(name);
    setOpen(false);
  };

  return (
    <div ref={ref} className="relative">
      <input
        type="text"
        value={query}
        disabled={disabled}
        maxLength={80}
        placeholder={placeholder}
        onChange={(e) => {
          setQuery(e.target.value);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        className="w-full px-4 py-2.5 rounded-xl border border-border bg-surface disabled:opacity-60 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
        autoComplete="off"
      />
      {open && !disabled && matches.length > 0 && (
        <ul className="absolute z-50 left-0 right-0 mt-1 max-h-64 overflow-auto bg-surface border border-border rounded-xl shadow-[var(--shadow-warm-lg)]">
          {matches.map((p, i) => (
            <li key={`${p.name}-${p.team}-${i}`}>
              <button
                type="button"
                onMouseDown={(e) => {
                  e.preventDefault();
                  pick(p.name);
                }}
                className="w-full text-left px-3 py-2 text-sm hover:bg-surface-hover flex items-center gap-2 border-b border-border/50 last:border-0"
              >
                <span className="text-foreground flex-1 truncate">{p.name}</span>
                <span className="text-xs text-muted shrink-0">
                  {p.flag} {p.team}
                  {p.position ? ` · ${p.position}` : ""}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
