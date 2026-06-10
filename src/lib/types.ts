export type ActionResult<T = void> =
  | (T extends void ? { ok: true } : { ok: true } & T)
  | { error: string };

export type Stage = "group" | "r32" | "r16" | "qf" | "sf" | "third" | "final";

export type Team = {
  id: string;
  name: string;
  code: string;
  group_letter: string | null;
  flag_emoji: string | null;
};

export type Match = {
  id: string;
  match_number: number;
  stage: Stage;
  group_letter: string | null;
  home_team_id: string | null;
  away_team_id: string | null;
  home_slot: string | null;
  away_slot: string | null;
  kickoff_at: string;
  status: "scheduled" | "finished";
  home_score: number | null;
  away_score: number | null;
  result_set_by: string | null;
  result_set_at: string | null;
};

export type MatchWithTeams = Match & {
  home_team: Team | null;
  away_team: Team | null;
};

export type MatchPrediction = {
  id: string;
  user_id: string;
  match_id: string;
  home_score: number;
  away_score: number;
};

export type LeaderboardRow = {
  user_id: string;
  name: string | null;
  email: string;
  total_points: number;
  match_points: number;
  macro_points: number;
  exact_count: number;
  result_count: number;
  predicted_count: number;
};

export const STAGE_LABELS: Record<Stage, string> = {
  group: "Fase de grupos",
  r32: "Dieciseisavos",
  r16: "Octavos",
  qf: "Cuartos",
  sf: "Semifinales",
  third: "Tercer puesto",
  final: "Final",
};

// Minutos antes del kickoff en que se cierran los pronósticos.
export const LOCK_MINUTES = 60;

export type GroupPlayer = { id: string; name: string; position: string | null };
export type GroupPlayersData = {
  letter: string;
  teams: { name: string; flag: string; players: GroupPlayer[] }[];
};
