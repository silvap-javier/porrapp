import type { Team } from "./types";

/** Etiqueta a mostrar para un lado de un partido: equipo real o slot TBD. */
export function sideLabel(
  team: Pick<Team, "name" | "flag_emoji"> | null,
  slot: string | null
): { flag: string; name: string } {
  if (team) return { flag: team.flag_emoji ?? "", name: team.name };
  return { flag: "⚪", name: slot ?? "Por definir" };
}

export function formatKickoff(iso: string): string {
  return new Date(iso).toLocaleString("es-ES", {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatDay(iso: string): string {
  return new Date(iso).toLocaleDateString("es-ES", {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
}
