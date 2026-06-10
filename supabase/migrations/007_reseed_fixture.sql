-- ============================================================================
-- PorrApp — 007_reseed_fixture
-- Reemplaza el fixture de plantilla por los 12 grupos OFICIALES del Mundial
-- 2026 (sorteo dic-2025). Para bases ya sembradas con 006 antiguo.
--
-- ⚠️  Borra todos los partidos y equipos y los recarga. Esto elimina en cascada
--     los pronósticos y resultados ya cargados (datos de prueba). Los macro
--     picks que apunten a equipos quedan a NULL.
--     Ejecutar SOLO durante la puesta a punto, antes de jugar en serio.
-- ============================================================================

DELETE FROM public.matches;
DELETE FROM public.teams;

DO $$
DECLARE
  group_letters TEXT[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];

  names TEXT[] := ARRAY[
    'México','Sudáfrica','Corea del Sur','República Checa',
    'Canadá','Bosnia y Herzegovina','Catar','Suiza',
    'Brasil','Marruecos','Haití','Escocia',
    'Estados Unidos','Paraguay','Australia','Turquía',
    'Alemania','Curazao','Costa de Marfil','Ecuador',
    'Países Bajos','Japón','Suecia','Túnez',
    'Bélgica','Egipto','Irán','Nueva Zelanda',
    'España','Cabo Verde','Arabia Saudí','Uruguay',
    'Francia','Senegal','Irak','Noruega',
    'Argentina','Argelia','Austria','Jordania',
    'Portugal','RD Congo','Uzbekistán','Colombia',
    'Inglaterra','Croacia','Ghana','Panamá'
  ];

  codes TEXT[] := ARRAY[
    'MEX','RSA','KOR','CZE',
    'CAN','BIH','QAT','SUI',
    'BRA','MAR','HAI','SCO',
    'USA','PAR','AUS','TUR',
    'GER','CUW','CIV','ECU',
    'NED','JPN','SWE','TUN',
    'BEL','EGY','IRN','NZL',
    'ESP','CPV','KSA','URU',
    'FRA','SEN','IRQ','NOR',
    'ARG','ALG','AUT','JOR',
    'POR','COD','UZB','COL',
    'ENG','CRO','GHA','PAN'
  ];

  flags TEXT[] := ARRAY[
    '🇲🇽','🇿🇦','🇰🇷','🇨🇿',
    '🇨🇦','🇧🇦','🇶🇦','🇨🇭',
    '🇧🇷','🇲🇦','🇭🇹','🏴󠁧󠁢󠁳󠁣󠁴󠁿',
    '🇺🇸','🇵🇾','🇦🇺','🇹🇷',
    '🇩🇪','🇨🇼','🇨🇮','🇪🇨',
    '🇳🇱','🇯🇵','🇸🇪','🇹🇳',
    '🇧🇪','🇪🇬','🇮🇷','🇳🇿',
    '🇪🇸','🇨🇻','🇸🇦','🇺🇾',
    '🇫🇷','🇸🇳','🇮🇶','🇳🇴',
    '🇦🇷','🇩🇿','🇦🇹','🇯🇴',
    '🇵🇹','🇨🇩','🇺🇿','🇨🇴',
    '🏴󠁧󠁢󠁥󠁮󠁧󠁿','🇭🇷','🇬🇭','🇵🇦'
  ];

  pat_h INT[] := ARRAY[1,3,1,4,4,2];
  pat_a INT[] := ARRAY[2,4,3,2,1,3];

  base_group TIMESTAMPTZ := '2026-06-11 16:00:00+00';
  base_ko    TIMESTAMPTZ := '2026-06-28 18:00:00+00';

  gi INT; j INT; mi INT; idx INT; k INT;
  team_ids UUID[];
  new_id UUID;
  mnum INT := 0;
BEGIN
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

  FOR k IN 1..16 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r32',
      'Clasificado grupos #' || (2 * k - 1),
      'Clasificado grupos #' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..8 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'r16',
      'Ganador R32-' || (2 * k - 1),
      'Ganador R32-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '8 hours'));
  END LOOP;

  FOR k IN 1..4 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'qf',
      'Ganador R16-' || (2 * k - 1),
      'Ganador R16-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  FOR k IN 1..2 LOOP
    mnum := mnum + 1;
    INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
    VALUES (mnum, 'sf',
      'Ganador QF-' || (2 * k - 1),
      'Ganador QF-' || (2 * k),
      base_ko + ((mnum - 73) * INTERVAL '12 hours'));
  END LOOP;

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'third', 'Perdedor SF-1', 'Perdedor SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  mnum := mnum + 1;
  INSERT INTO public.matches (match_number, stage, home_slot, away_slot, kickoff_at)
  VALUES (mnum, 'final', 'Ganador SF-1', 'Ganador SF-2',
    base_ko + ((mnum - 73) * INTERVAL '12 hours'));

  RAISE NOTICE 'PorrApp reseed completo: 48 equipos, % partidos.', mnum;
END $$;
