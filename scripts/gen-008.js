// Genera supabase/migrations/008_real_fixture.sql a partir de fixture.json (FIFA).
// Horarios de la fuente en ET (EDT, UTC-4 en jun/jul) → UTC = ET + 4h.
const fs = require("fs");
const path = require("path");

const d = require("../fixture.json");
const nodes = d.richtext.content;

function flat(n) {
  if (n.nodeType === "text") return n.value;
  if (n.content) return n.content.map(flat).join("");
  return "";
}
const MONTH = { enero:1,febrero:2,marzo:3,abril:4,mayo:5,junio:6,julio:7,agosto:8,septiembre:9,octubre:10,noviembre:11,diciembre:12 };
function parseDate(h) {
  const m = h.match(/(\d{1,2}) de ([a-zA-Zé]+) (\d{4})/);
  if (!m || !MONTH[m[2].toLowerCase()]) return null;
  return { d:+m[1], mo:MONTH[m[2].toLowerCase()], y:+m[3] };
}

// --- 48 equipos (orden de grupos, igual que 007) ---
const TEAMS = [
  ["México","MEX","A","🇲🇽"],["Sudáfrica","RSA","A","🇿🇦"],["Corea del Sur","KOR","A","🇰🇷"],["República Checa","CZE","A","🇨🇿"],
  ["Canadá","CAN","B","🇨🇦"],["Bosnia y Herzegovina","BIH","B","🇧🇦"],["Catar","QAT","B","🇶🇦"],["Suiza","SUI","B","🇨🇭"],
  ["Brasil","BRA","C","🇧🇷"],["Marruecos","MAR","C","🇲🇦"],["Haití","HAI","C","🇭🇹"],["Escocia","SCO","C","🏴󠁧󠁢󠁳󠁣󠁴󠁿"],
  ["Estados Unidos","USA","D","🇺🇸"],["Paraguay","PAR","D","🇵🇾"],["Australia","AUS","D","🇦🇺"],["Turquía","TUR","D","🇹🇷"],
  ["Alemania","GER","E","🇩🇪"],["Curazao","CUW","E","🇨🇼"],["Costa de Marfil","CIV","E","🇨🇮"],["Ecuador","ECU","E","🇪🇨"],
  ["Países Bajos","NED","F","🇳🇱"],["Japón","JPN","F","🇯🇵"],["Suecia","SWE","F","🇸🇪"],["Túnez","TUN","F","🇹🇳"],
  ["Bélgica","BEL","G","🇧🇪"],["Egipto","EGY","G","🇪🇬"],["Irán","IRN","G","🇮🇷"],["Nueva Zelanda","NZL","G","🇳🇿"],
  ["España","ESP","H","🇪🇸"],["Cabo Verde","CPV","H","🇨🇻"],["Arabia Saudí","KSA","H","🇸🇦"],["Uruguay","URU","H","🇺🇾"],
  ["Francia","FRA","I","🇫🇷"],["Senegal","SEN","I","🇸🇳"],["Irak","IRQ","I","🇮🇶"],["Noruega","NOR","I","🇳🇴"],
  ["Argentina","ARG","J","🇦🇷"],["Argelia","ALG","J","🇩🇿"],["Austria","AUT","J","🇦🇹"],["Jordania","JOR","J","🇯🇴"],
  ["Portugal","POR","K","🇵🇹"],["RD Congo","COD","K","🇨🇩"],["Uzbekistán","UZB","K","🇺🇿"],["Colombia","COL","K","🇨🇴"],
  ["Inglaterra","ENG","L","🏴󠁧󠁢󠁥󠁮󠁧󠁿"],["Croacia","CRO","L","🇭🇷"],["Ghana","GHA","L","🇬🇭"],["Panamá","PAN","L","🇵🇦"],
];

// FIFA name (como aparece en el fixture) → código
const ALIAS = {
  "México":"MEX","Sudáfrica":"RSA","República de Corea":"KOR","Corea del Sur":"KOR","República Checa":"CZE",
  "Canadá":"CAN","Bosnia y Herzegovina":"BIH","Catar":"QAT","Suiza":"SUI",
  "Brasil":"BRA","Marruecos":"MAR","Haití":"HAI","Escocia":"SCO",
  "Estados Unidos":"USA","Paraguay":"PAR","Australia":"AUS","Turquía":"TUR",
  "Alemania":"GER","Curazao":"CUW","Costa de Marfil":"CIV","Ecuador":"ECU",
  "Países Bajos":"NED","Japón":"JPN","Suecia":"SWE","Túnez":"TUN",
  "Bélgica":"BEL","Egipto":"EGY","Irán":"IRN","RI de Irán":"IRN","Nueva Zelanda":"NZL",
  "España":"ESP","Cabo Verde":"CPV","Arabia Saudí":"KSA","Uruguay":"URU",
  "Francia":"FRA","Senegal":"SEN","Irak":"IRQ","Noruega":"NOR",
  "Argentina":"ARG","Argelia":"ALG","Austria":"AUT","Jordania":"JOR",
  "Portugal":"POR","RD Congo":"COD","Uzbekistán":"UZB","Colombia":"COL",
  "Inglaterra":"ENG","Croacia":"CRO","Ghana":"GHA","Panamá":"PAN",
};

function code(name) {
  const c = ALIAS[name.trim()];
  if (!c) throw new Error("Sin código para equipo: «" + name + "»");
  return c;
}
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
function etToUtc(date, h, min) {
  return new Date(Date.UTC(date.y, date.mo - 1, date.d, h + 4, min)).toISOString();
}

// --- parseo ---
let cur = null;
const group = [], ko = [];
for (const n of nodes) {
  if (n.nodeType === "heading-4") { cur = parseDate(flat(n).trim()); continue; }
  if (n.nodeType !== "paragraph" || !cur) continue;
  for (const line of flat(n).split(/\n/).map((s) => s.trim()).filter(Boolean)) {
    let m;
    if ((m = line.match(/^(\d{1,2}):(\d{2})\s*-\s*(.+?)\s+v\s+(.+?)\s*[–-]\s*Grupo\s+([A-L])\s*-\s*(.+?)\s*$/))) {
      group.push({ h:+m[1], min:+m[2], home:code(m[3]), away:code(m[4]), g:m[5], venue:m[6].trim(), kickoff: etToUtc(cur,+m[1],+m[2]) });
    } else if ((m = line.match(/^Partido\s+(\d+)\s*[–-]\s*(.+?)\s+v\s+(.+?)\s*-\s*(Estadio\s+.+?)\s*$/))) {
      // Eliminatorias: sin hora en la fuente → 20:00 UTC del día como plantilla.
      ko.push({ num:+m[1], home:m[2].trim(), away:m[3].trim(), venue:m[4].trim(),
        kickoff: new Date(Date.UTC(cur.y, cur.mo - 1, cur.d, 20, 0)).toISOString() });
    } else { throw new Error("Línea no reconocida: " + line); }
  }
}
if (group.length !== 72 || ko.length !== 32) throw new Error(`Conteo inesperado: ${group.length} grupos, ${ko.length} KO`);

function koStage(num) {
  if (num <= 88) return "r32";
  if (num <= 96) return "r16";
  if (num <= 100) return "qf";
  if (num <= 102) return "sf";
  if (num === 103) return "third";
  return "final";
}

// --- SQL ---
const L = [];
L.push("-- ============================================================================");
L.push("-- PorrApp — 008_real_fixture");
L.push("-- Fixture OFICIAL del Mundial 2026 (FIFA, calendario definitivo 6-dic-2025).");
L.push("-- Autocontenida: fija los 48 equipos y reconstruye los 104 partidos con sede,");
L.push("-- match_number oficial y kickoff en UTC (la fuente da horarios en ET = UTC-4).");
L.push("-- Generada desde fixture.json por scripts/gen-008.js — no editar a mano.");
L.push("--");
L.push("-- ⚠️  Borra equipos y partidos y los recarga (elimina en cascada pronósticos");
L.push("--     y resultados de prueba). Ejecutar durante la puesta a punto.");
L.push("-- ============================================================================");
L.push("");
L.push("ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS venue TEXT;");
L.push("");
L.push("DELETE FROM public.matches;");
L.push("DELETE FROM public.teams;");
L.push("");
L.push("-- 48 selecciones");
L.push("INSERT INTO public.teams (name, code, group_letter, flag_emoji) VALUES");
L.push(TEAMS.map((t) => `  (${q(t[0])}, ${q(t[1])}, ${q(t[2])}, ${q(t[3])})`).join(",\n") + ";");
L.push("");
L.push("-- 72 partidos de fase de grupos (equipos por código, kickoff UTC, sede)");
L.push("INSERT INTO public.matches (match_number, stage, group_letter, home_team_id, away_team_id, kickoff_at, venue) VALUES");
L.push(group.map((m, i) =>
  `  (${i + 1}, 'group', ${q(m.g)}, ` +
  `(SELECT id FROM public.teams WHERE code=${q(m.home)}), ` +
  `(SELECT id FROM public.teams WHERE code=${q(m.away)}), ` +
  `${q(m.kickoff)}, ${q(m.venue)})`
).join(",\n") + ";");
L.push("");
L.push("-- 32 partidos de eliminatorias (equipos TBD: etiquetas oficiales de cruce)");
L.push("INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at, venue) VALUES");
L.push(ko.map((m) =>
  `  (${m.num}, ${q(koStage(m.num))}, ${q(m.home)}, ${q(m.away)}, ${q(m.kickoff)}, ${q(m.venue)})`
).join(",\n") + ";");
L.push("");

const out = path.join(__dirname, "..", "supabase", "migrations", "008_real_fixture.sql");
fs.writeFileSync(out, L.join("\n") + "\n");
console.log("OK →", out);
console.log("grupos:", group.length, "ko:", ko.length);
console.log("primer partido:", group[0].kickoff, group[0].home, "v", group[0].away, "@", group[0].venue);
console.log("KO 73:", ko[0].home, "v", ko[0].away, "@", ko[0].venue, ko[0].kickoff);
console.log("final 104:", ko[ko.length-1].home, "v", ko[ko.length-1].away, "@", ko[ko.length-1].venue);
