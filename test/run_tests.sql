-- Test suite. Run from the repository root against a scratch database:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f test/run_tests.sql
--
-- Installs sql/cologne_phonetic.sql, asserts every case in test/corpus.json, then the rules of
-- the function contract that the corpus cannot express (NULL, STRICT/IMMUTABLE/PARALLEL SAFE
-- flags, use in a generated column, never raising). Any failure aborts psql with a non-zero
-- exit code and a message naming the input, the expected value and the actual one.

\set ON_ERROR_STOP on
\set QUIET on
\set corpus `cat test/corpus.json`

BEGIN;
\i sql/cologne_phonetic.sql

CREATE TEMP TABLE corpus AS
SELECT ordinality AS n,
       c ->> 'input'    AS input,
       c ->> 'expected' AS expected
FROM jsonb_array_elements(:'corpus'::jsonb) WITH ORDINALITY AS t(c, ordinality);

-- 1. The corpus is the specification: every case must match.
DO $$
DECLARE
  bad record;
  n_bad int := 0;
  n_all int;
BEGIN
  SELECT count(*) INTO n_all FROM corpus;
  IF n_all < 200 THEN
    RAISE EXCEPTION 'corpus has only % cases, expected at least 200', n_all;
  END IF;

  FOR bad IN
    SELECT n, input, expected, cologne_phonetic(input) AS actual
    FROM corpus
    WHERE cologne_phonetic(input) IS DISTINCT FROM expected
    ORDER BY n
  LOOP
    n_bad := n_bad + 1;
    RAISE WARNING 'corpus case %: input % expected % got %', bad.n, to_json(bad.input), bad.expected, bad.actual;
  END LOOP;

  IF n_bad > 0 THEN
    RAISE EXCEPTION '% of % corpus cases failed', n_bad, n_all;
  END IF;
  RAISE NOTICE 'corpus: % cases pass', n_all;
END $$;

-- 2. The corpus discriminates: a function returning a constant could not pass it.
DO $$
DECLARE k int;
BEGIN
  SELECT count(DISTINCT expected) INTO k FROM corpus;
  ASSERT k >= 20, format('corpus has only %s distinct codes', k);
END $$;

-- 3. Case is irrelevant (ASCII case folded by hand so the test does not depend on the collation).
DO $$
DECLARE bad record;
BEGIN
  FOR bad IN
    SELECT input, expected,
           cologne_phonetic(translate(input, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')) AS up,
           cologne_phonetic(translate(input, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')) AS low
    FROM corpus
  LOOP
    ASSERT bad.up = bad.expected,  format('upper-cased %s gave %s, expected %s', to_json(bad.input), bad.up, bad.expected);
    ASSERT bad.low = bad.expected, format('lower-cased %s gave %s, expected %s', to_json(bad.input), bad.low, bad.expected);
  END LOOP;
END $$;

-- 4. Contract: NULL in, NULL out; flags that make it usable in generated columns and indexes.
DO $$
DECLARE p pg_proc;
BEGIN
  SELECT * INTO STRICT p FROM pg_proc WHERE proname = 'cologne_phonetic' AND pronamespace = 'public'::regnamespace;
  ASSERT p.provolatile = 'i', 'function must be IMMUTABLE';
  ASSERT p.proparallel = 's', 'function must be PARALLEL SAFE';
  ASSERT p.proisstrict,       'function must be STRICT';
  ASSERT cologne_phonetic(NULL) IS NULL, 'NULL must give NULL';
  ASSERT pg_get_function_arguments(p.oid) = 'input text' AND pg_get_function_result(p.oid) = 'text', 'signature must be text -> text';
END $$;

-- 5. Pairs from the brief that must collide, and a few that must not.
DO $$
BEGIN
  ASSERT cologne_phonetic('Müller')  = cologne_phonetic('Mueller');
  ASSERT cologne_phonetic('Müller')  = cologne_phonetic('MÜLLER');
  ASSERT cologne_phonetic('Schröder') = cologne_phonetic('Schroeder');
  ASSERT cologne_phonetic('Weiß')    = cologne_phonetic('Weiss');
  ASSERT cologne_phonetic('Meyer')   = cologne_phonetic('Maier');
  ASSERT cologne_phonetic('Meyer')   = cologne_phonetic('Mayr');
  ASSERT cologne_phonetic('Schmidt') = cologne_phonetic('Schmitt');
  ASSERT cologne_phonetic('Krause')  = cologne_phonetic('Krauße');
  ASSERT cologne_phonetic('O''Brien') = cologne_phonetic('OBrien');
  ASSERT cologne_phonetic('Meyer-Schmidt') = cologne_phonetic('MeyerSchmidt');
  ASSERT cologne_phonetic('François') = cologne_phonetic('Francois');

  ASSERT cologne_phonetic('Müller')  <> cologne_phonetic('Meyer');
  ASSERT cologne_phonetic('Schmidt') <> cologne_phonetic('Schneider');
  ASSERT cologne_phonetic('Fischer') <> cologne_phonetic('Wagner');
  ASSERT cologne_phonetic('Becker')  <> cologne_phonetic('Hoffmann');
END $$;

-- 6. Never raises, and degenerate input gives '' rather than an error.
DO $$
BEGIN
  ASSERT cologne_phonetic('') = '';
  ASSERT cologne_phonetic('''') = '';
  ASSERT cologne_phonetic('123') = '';
  ASSERT cologne_phonetic('!?,.;:-_/\()[]{}<>|@#$%^&*+=~`') = '';
  ASSERT cologne_phonetic('Пушкин') = '';
  ASSERT cologne_phonetic('北京') = '';
  ASSERT cologne_phonetic('😀') = '';
  ASSERT cologne_phonetic(E'\t\n ') = '';
  ASSERT cologne_phonetic(E'M\u00fcller') = '657';   -- precomposed ü
  ASSERT cologne_phonetic(E'Mu\u0308ller') = '657';  -- u + combining diaeresis
  ASSERT cologne_phonetic(repeat('Schmidt', 2000)) ~ '^[0-9]+$';       -- 14 000 characters
  ASSERT length(cologne_phonetic(repeat('x', 200))) > 0;
  ASSERT cologne_phonetic(repeat('-', 1000)) = '';
END $$;

-- 7. Usable as a STORED generated column and in an index; writes of awkward values succeed.
CREATE TEMP TABLE people (
  full_name   text,
  name_sounds text GENERATED ALWAYS AS (cologne_phonetic(full_name)) STORED
);
CREATE INDEX ON people (name_sounds);
INSERT INTO people (full_name)
SELECT input FROM corpus
UNION ALL VALUES (NULL), (''), ('Иван Müller'), ('東京'), ('...'), (repeat('ä', 500));

DO $$
DECLARE k int;
BEGIN
  SELECT count(*) INTO k FROM people WHERE name_sounds = cologne_phonetic('Mueller');
  ASSERT k >= 5, format('expected the Müller variants in the corpus to be found, got %s rows', k);
  SELECT count(*) INTO k FROM people WHERE full_name IS NULL AND name_sounds IS NULL;
  ASSERT k = 1, 'NULL name must give NULL code in the generated column';
  SELECT count(*) INTO k FROM people p JOIN corpus c ON c.input = p.full_name WHERE p.name_sounds <> c.expected;
  ASSERT k = 0, 'generated column disagrees with the corpus';
END $$;

ROLLBACK;
\echo All tests passed.
