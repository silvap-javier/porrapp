-- ============================================================================
-- PorrApp — 006_seed_worldcup2026
-- Carga inicial del Mundial 2026: 48 selecciones en 12 grupos (A–L), 72
-- partidos de fase de grupos (round-robin) y 32 de eliminatorias.
--
-- ⚠️  PLANTILLA EDITABLE: el reparto exacto de grupos y los horarios son una
--     base de desarrollo. La app permite que cualquier usuario corrija equipos,
--     cruces y resultados desde el panel /resultados, así que se ajusta en vivo
--     contra el calendario oficial FIFA.
--
-- Idempotente: no hace nada si ya hay partidos cargados.
-- ============================================================================

DO $$
DECLARE
  group_letters TEXT[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];

  names TEXT[] := ARRAY[
    'México','Croacia','Corea del Sur','Ghana',
    'Canadá','Bélgica','Ecuador','Catar',
    'Estados Unidos','Países Bajos','Senegal','Arabia Saudí',
    'Argentina','Japón','Nigeria','Australia',
    'Francia','Dinamarca','Egipto','Costa Rica',
    'Brasil','Suiza','Camerún','Irán',
    'España','Uruguay','Costa de Marfil','Nueva Zelanda',
    'Inglaterra','Colombia','Marruecos','Panamá',
    'Portugal','Suecia','Túnez','Jamaica',
    'Alemania','Perú','Argelia','Honduras',
    'Italia','Chile','Sudáfrica','Eslovenia',
    'Polonia','Serbia','Malí','Uzbekistán'
  ];

  codes TEXT[] := ARRAY[
    'MEX','CRO','KOR','GHA',
    'CAN','BEL','ECU','QAT',
    'USA','NED','SEN','KSA',
    'ARG','JPN','NGA','AUS',
    'FRA','DEN','EGY','CRC',
    'BRA','SUI','CMR','IRN',
    'ESP','URU','CIV','NZL',
    'ENG','COL','MAR','PAN',
    'POR','SWE','TUN','JAM',
    'GER','PER','ALG','HON',
    'ITA','CHI','RSA','SVN',
    'POL','SRB','MLI','UZB'
  ];

  flags TEXT[] := ARRAY[
    '🇲🇽','🇭🇷','🇰🇷','🇬🇭',
    '🇨🇦','🇧🇪','🇪🇨','🇶🇦',
    '🇺🇸','🇳🇱','🇸🇳','🇸🇦',
    '🇦🇷','🇯🇵','🇳🇬','🇦🇺',
    '🇫🇷','🇩🇰','🇪🇬','🇨🇷',
    '🇧🇷','🇨🇭','🇨🇲','🇮🇷',
    '🇪🇸','🇺🇾','🇨🇮','🇳🇿',
    '🇬🇧','🇨🇴','🇲🇦','🇵🇦',
    '🇵🇹','🇸🇪','🇹🇳','🇯🇲',
    '🇩🇪','🇵🇪','🇩🇿','🇭🇳',
    '🇮🇹','🇨🇱','🇿🇦','🇸🇮',
    '🇵🇱','🇷🇸','🇲🇱','🇺🇿'
  ];

  -- Round-robin de 4 equipos (posiciones 1–4): 6 partidos.
  pat_h INT[] := ARRAY[1,3,1,4,4,2];
  pat_a INT[] := ARRAY[2,4,3,2,1,3];

  base_group TIMESTAMPTZ := '2026-06-11 16:00:00+00';
  base_ko    TIMESTAMPTZ := '2026-06-28 18:00:00+00';

  gi INT; j INT; mi INT; idx INT; k INT;
  team_ids UUID[];
  new_id UUID;
  mnum INT := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.matches) THEN
    RAISE NOTICE 'PorrApp seed: ya hay partidos cargados, no se hace nada.';
    RETURN;
  END IF;

  -- ---- Equipos + partidos de grupos ----
  FOR gi IN 0..11 LOOP
    team_ids := ARRAY[]::UUID[];
    FOR j IN 1..4 LOOP
      idx := gi * 4 + j;
      INSERT INTO public.teams (name, code, group_letter, flag_emoji)
      VALUES (names[idx], codes[idx], group_letters[gi + 1], flags[idx])
      RETURNING id INTO new_id;
      team_ids := array_append(team_ids, new_id);
    END LOOP;

    FOR mi IN 1..6 LOOP
      mnum := mnum + 1;
      INSERT INTO public.matches
        (match_number, stage, group_letter, home_team_id, away_team_id, kickoff_at)
      VALUES (
        mnum, 'group', group_letters[gi + 1],
        team_ids[pat_h[mi]], team_ids[pat_a[mi]],
        base_group + ((mnum - 1) * INTERVAL '6 hours')
      );
    END LOOP;
  END LOOP;

  -- ---- Eliminatorias (equipos TBD, etiquetas de cruce) ----
  -- Dieciseisavos (R32): 16 partidos (mnum 73–88)
  FOR k IN 1..16 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r32',
      'Clasificado grupos #' || (2 * k - 1),
      'Clasificado grupos #' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  -- Octavos (R16): 8 partidos (mnum 89–96)
  FOR k IN 1..8 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r16',
      'Ganador R32-' || (2 * k - 1),
      'Ganador R32-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  -- Cuartos (QF): 4 partidos (mnum 97–100)
  FOR k IN 1..4 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'qf',
      'Ganador R16-' || (2 * k - 1),
      'Ganador R16-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  -- Semifinales (SF): 2 partidos (mnum 101–102)
  FOR k IN 1..2 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'sf',
      'Ganador QF-' || (2 * k - 1),
      'Ganador QF-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  -- Tercer puesto (mnum 103)
  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'third', 'Perdedor SF-1', 'Perdedor SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  -- Final (mnum 104)
  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'final', 'Ganador SF-1', 'Ganador SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  RAISE NOTICE 'PorrApp seed completo: 48 equipos, % partidos.', mnum;
END $$;
