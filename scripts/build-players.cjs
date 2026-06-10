const cheerio = require("cheerio");
const fs = require("fs");

const REPO = "/home/silvap/Documentos/GitHub/Personales/porrapp";
const URL = "https://en.wikipedia.org/wiki/2026_FIFA_World_Cup_squads";

// Heading inglés (Wikipedia) → nuestro código de selección
const ALIAS = {
  "Mexico": "MEX", "South Africa": "RSA", "South Korea": "KOR", "Korea Republic": "KOR",
  "Czech Republic": "CZE", "Czechia": "CZE",
  "Canada": "CAN", "Bosnia and Herzegovina": "BIH", "Qatar": "QAT", "Switzerland": "SUI",
  "Brazil": "BRA", "Morocco": "MAR", "Haiti": "HAI", "Scotland": "SCO",
  "United States": "USA", "Paraguay": "PAR", "Australia": "AUS", "Turkey": "TUR", "Türkiye": "TUR",
  "Germany": "GER", "Curaçao": "CUW", "Curacao": "CUW", "Ivory Coast": "CIV", "Côte d'Ivoire": "CIV",
  "Ecuador": "ECU", "Netherlands": "NED", "Japan": "JPN", "Sweden": "SWE", "Tunisia": "TUN",
  "Belgium": "BEL", "Egypt": "EGY", "Iran": "IRN", "IR Iran": "IRN", "New Zealand": "NZL",
  "Spain": "ESP", "Cape Verde": "CPV", "Cabo Verde": "CPV", "Saudi Arabia": "KSA", "Uruguay": "URU",
  "France": "FRA", "Senegal": "SEN", "Iraq": "IRQ", "Norway": "NOR",
  "Argentina": "ARG", "Algeria": "ALG", "Austria": "AUT", "Jordan": "JOR",
  "Portugal": "POR", "DR Congo": "COD", "Democratic Republic of the Congo": "COD",
  "Uzbekistan": "UZB", "Colombia": "COL", "England": "ENG", "Croatia": "CRO", "Ghana": "GHA", "Panama": "PAN",
};

const clean = (s) => (s || "").replace(/\[.*?\]/g, "").replace(/\s+/g, " ").trim();
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";

async function main() {
  const html = await (await fetch(URL)).text();
  const $ = cheerio.load(html);

  const byCode = {};
  let current = null;

  $("h2, h3, table").each((_, el) => {
    const tag = el.tagName.toLowerCase();
    if (tag === "h2" || tag === "h3") {
      const name = clean($(el).find(".mw-headline").text() || $(el).text());
      if (ALIAS[name]) current = ALIAS[name];
      return;
    }
    // table
    const cls = $(el).attr("class") || "";
    if (!current || !cls.includes("plainrowheaders")) return;

    const players = [];
    $(el).find("tr").each((i, tr) => {
      const cells = $(tr).find("th, td");
      if (cells.length < 7) return;
      const nameCell = $(tr).find('th[scope="row"]').first();
      if (!nameCell.length) return;
      const number = parseInt(clean($(cells[0]).text()), 10);
      const position = (clean($(cells[1]).text()).match(/[A-Za-z]{2}/) || [""])[0];
      const name = clean(nameCell.text());
      const club = clean($(cells[cells.length - 1]).text());
      if (!name) return;
      players.push({ name, position, number: Number.isFinite(number) ? number : null, club });
    });

    if (players.length) byCode[current] = players;
    current = null; // un solo squad por equipo
  });

  const codes = Object.keys(byCode);
  const total = codes.reduce((n, c) => n + byCode[c].length, 0);

  fs.writeFileSync(`${REPO}/worldcup_players.json`, JSON.stringify(byCode, null, 2));

  // --- SQL ---
  const L = [];
  L.push("-- ============================================================================");
  L.push("-- PorrApp — 017_seed_players");
  L.push("-- Plantillas del Mundial 2026 (Wikipedia, en.wikipedia 2026_FIFA_World_Cup_squads).");
  L.push("-- Generado por scripts/build-players.cjs — no editar a mano.");
  L.push("-- Idempotente: borra y recarga players.");
  L.push("-- ============================================================================");
  L.push("");
  L.push("DELETE FROM public.players;");
  L.push("");
  L.push("INSERT INTO public.players (name, team_id, position, shirt_number, club) VALUES");
  const rows = [];
  for (const code of codes) {
    for (const p of byCode[code]) {
      rows.push(
        `  (${q(p.name)}, (SELECT id FROM public.teams WHERE code=${q(code)}), ` +
        `${p.position ? q(p.position) : "NULL"}, ${p.number ?? "NULL"}, ${p.club ? q(p.club) : "NULL"})`
      );
    }
  }
  L.push(rows.join(",\n") + ";");
  L.push("");
  fs.writeFileSync(`${REPO}/supabase/migrations/017_seed_players.sql`, L.join("\n"));

  // Reporte
  console.log("Equipos:", codes.length, "/ 48");
  console.log("Jugadores totales:", total);
  const missing = Object.values(ALIAS).filter((c, i, a) => a.indexOf(c) === i).filter((c) => !byCode[c]);
  console.log("Códigos sin jugadores:", missing.length ? missing.join(", ") : "ninguno");
  console.log("Ejemplo por equipo (nº):", codes.slice(0, 6).map((c) => `${c}:${byCode[c].length}`).join("  "));
}
main().catch((e) => { console.error("ERR", e.message); process.exit(1); });
