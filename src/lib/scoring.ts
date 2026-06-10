import { LOCK_MINUTES } from "./types";

export const POINTS_EXACT = 3;
export const POINTS_RESULT = 1;
export const POINTS_CHAMPION = 10;
export const POINTS_RUNNERUP = 5;
export const POINTS_TOP_SCORER = 5;

function sign(n: number): number {
  return n > 0 ? 1 : n < 0 ? -1 : 0;
}

/**
 * Puntos de un pronóstico de partido. Espejo TS de la función SQL `score_match`
 * para poder mostrar el desglose en la UI sin ir a la base.
 *   · Marcador exacto = POINTS_EXACT + POINTS_RESULT (3 + 1 = 4)
 *   · Solo resultado correcto (1X2) = POINTS_RESULT (1)
 *   · Fallo = 0
 */
export function scoreMatch(
  predHome: number,
  predAway: number,
  actualHome: number,
  actualAway: number
): number {
  if (predHome === actualHome && predAway === actualAway) {
    return POINTS_EXACT + POINTS_RESULT;
  }
  if (sign(predHome - predAway) === sign(actualHome - actualAway)) {
    return POINTS_RESULT;
  }
  return 0;
}

/** ¿Siguen abiertos los pronósticos de un partido? (cierran LOCK_MINUTES antes). */
export function isMatchOpen(kickoffAt: string, status: string): boolean {
  if (status === "finished") return false;
  const kickoff = new Date(kickoffAt).getTime();
  const lockAt = kickoff - LOCK_MINUTES * 60 * 1000;
  return Date.now() < lockAt;
}
