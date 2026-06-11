import { Link } from "@/i18n/navigation";

function Rule({ pts, title, body }: { pts: string; title: string; body: string }) {
  return (
    <div className="flex items-start gap-3 bg-surface border border-border rounded-2xl p-4">
      <span className="flex-shrink-0 min-w-10 h-10 px-2 rounded-xl bg-primary/10 text-primary font-bold flex items-center justify-center">
        {pts}
      </span>
      <div>
        <p className="font-semibold text-foreground">{title}</p>
        <p className="text-sm text-muted leading-relaxed mt-0.5">{body}</p>
      </div>
    </div>
  );
}

export default function ReglasPage() {
  return (
    <div className="max-w-2xl mx-auto px-3 py-6 space-y-6">
      <header className="px-1">
        <Link href="/dashboard" className="text-sm text-muted hover:text-foreground">
          ← Volver
        </Link>
        <h1 className="text-2xl font-bold text-foreground font-display mt-2">📖 Reglas y puntuación</h1>
        <p className="text-sm text-muted mt-1">Así se juega y se reparten los puntos en PorrApp.</p>
      </header>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Puntos por partido</h2>
        <Rule
          pts="4"
          title="Marcador exacto"
          body="Aciertas el resultado exacto (p. ej. 2-1). Suma el bonus de exacto (3) más el de resultado (1) = 4 puntos."
        />
        <Rule
          pts="1"
          title="Solo resultado (1X2)"
          body="Aciertas quién gana o el empate, pero no el marcador exacto. 1 punto."
        />
        <Rule pts="0" title="Fallo" body="Si no aciertas ni el ganador ni el empate, 0 puntos." />
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Picks de torneo</h2>
        <Rule pts="10" title="Campeón" body="Aciertas la selección que gana el Mundial." />
        <Rule pts="5" title="Subcampeón" body="Aciertas el finalista que pierde la final." />
        <Rule pts="5" title="Goleador" body="Aciertas el máximo goleador del torneo (Bota de Oro)." />
        <p className="text-xs text-muted px-1">
          Los picks de torneo se cierran 60 minutos antes del primer partido del Mundial.
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Primeros y segundos de grupo</h2>
        <Rule pts="3" title="1º del grupo" body="Aciertas qué selección queda primera en un grupo. 3 puntos por grupo." />
        <Rule pts="2" title="2º del grupo" body="Aciertas qué selección queda segunda en un grupo. 2 puntos por grupo." />
        <p className="text-xs text-muted px-1">
          Se resuelven cuando el grupo termina todos sus partidos. El orden sale de la clasificación real (puntos, diferencia de goles y goles a favor).
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Pichichi de grupo</h2>
        <Rule pts="3" title="Goleador del grupo" body="Aciertas el máximo goleador de cada grupo. 3 puntos por grupo." />
        <p className="text-xs text-muted px-1">
          También son picks: se cierran 60 minutos antes del primer partido.
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Tu puntuación total</h2>
        <div className="bg-surface border border-border rounded-2xl p-4 text-sm text-foreground leading-relaxed">
          <p className="font-medium">Total = partidos + picks de torneo + primeros/segundos de grupo + pichichis de grupo.</p>
          <p className="text-muted mt-1.5">Todo se suma en un único marcador, igual en todas tus ligas.</p>
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-foreground px-1">Cómo funciona</h2>
        <ul className="bg-surface border border-border rounded-2xl p-4 space-y-2.5 text-sm text-foreground">
          <li>⏰ <strong>Cierre:</strong> cada partido cierra sus pronósticos <strong>60 minutos antes</strong> del inicio. Después no se puede editar.</li>
          <li>📝 <strong>Una boleta:</strong> tu pronóstico es único y <strong>cuenta en todas tus ligas</strong>. No rellenas una boleta por liga.</li>
          <li>🏆 <strong>Ranking:</strong> ganas por la suma total de puntos. En caso de empate, manda quien tenga más <strong>aciertos exactos</strong>.</li>
          <li>✅ <strong>Resultados:</strong> cualquiera puede cargar el marcador real de un partido; queda registrado quién lo hizo, así que jugamos limpio.</li>
          <li>💰 <strong>Bote:</strong> si tu liga tiene cuota, el bote (cuota × miembros) es solo informativo. PorrApp no gestiona pagos.</li>
        </ul>
      </section>
    </div>
  );
}
