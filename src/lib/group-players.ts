import type { GroupPlayersData } from "./types";

export type PlayerRow = {
  id: string;
  name: string;
  position: string | null;
  team: { name: string; group_letter: string | null; flag_emoji: string | null } | null;
};

/** Agrupa jugadores por grupo → equipo, para los selectores de pichichi. */
export function buildGroupPlayers(rows: PlayerRow[]): GroupPlayersData[] {
  const byGroup = new Map<
    string,
    Map<string, { name: string; flag: string; players: { id: string; name: string; position: string | null }[] }>
  >();

  for (const p of rows) {
    const g = p.team?.group_letter;
    if (!g) continue;
    if (!byGroup.has(g)) byGroup.set(g, new Map());
    const teams = byGroup.get(g)!;
    const tname = p.team!.name;
    if (!teams.has(tname)) {
      teams.set(tname, { name: tname, flag: p.team!.flag_emoji ?? "", players: [] });
    }
    teams.get(tname)!.players.push({ id: p.id, name: p.name, position: p.position });
  }

  return Array.from(byGroup.keys())
    .sort()
    .map((letter) => ({ letter, teams: Array.from(byGroup.get(letter)!.values()) }));
}

export type FlatPlayer = { name: string; team: string; flag: string; position: string | null };

/** Lista plana de jugadores (todas las selecciones) para el buscador de goleador del torneo. */
export function flatPlayers(rows: PlayerRow[]): FlatPlayer[] {
  return rows
    .map((p) => ({
      name: p.name,
      team: p.team?.name ?? "",
      flag: p.team?.flag_emoji ?? "",
      position: p.position,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}
