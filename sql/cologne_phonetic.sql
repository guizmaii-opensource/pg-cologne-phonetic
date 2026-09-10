-- cologne_phonetic(text) -> text
--
-- Kölner Phonetik (Cologne phonetics, H. J. Postel 1969): maps a word to a digit string so that
-- words which sound alike in German share a code. Müller, Mueller and Muller all give 657.
--
-- Requires PostgreSQL 18 or later and a UTF8 database. The version floor is a scope decision,
-- not a technical one: nothing below needs 18, but 18 is the only version this repo tests.
--
-- Usage:
--   ALTER TABLE people ADD COLUMN name_sounds text
--       GENERATED ALWAYS AS (cologne_phonetic(full_name)) STORED;
--   SELECT * FROM people WHERE name_sounds = cologne_phonetic('Mueller');
--
-- Behaviour (test/corpus.json is the specification; see README for how it was produced):
--   NULL -> NULL. '' -> ''. Input with no codeable letter -> ''. Anything else -> digits.
--   Case does not matter. Input is NFC-normalised. ä/ö/ü fold to a/o/u, ß to ss, ſ to s, the
--   ff/fi/fl/st ligatures to their letters, and the accented letters of Latin-1 Supplement and
--   Latin Extended-A to their base letter (é -> e, ç -> c, ø -> o, ł -> l). Letters outside
--   those blocks (Vietnamese ơ, ạ; Latin Extended Additional ṇ, ṣ) are not folded and are not
--   coded. Everything that is not A-Z after the fold is not coded,
--   but it is still visible to the one-character lookahead some rules use: "St-Cyr" codes the T
--   as if followed by "-", "StCyr" as if followed by "C". Non-Latin script codes to ''.
--   Never raises.

DO $$
BEGIN
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE EXCEPTION 'cologne_phonetic requires PostgreSQL 18 or later, found %',
      current_setting('server_version');
  END IF;
  -- The fold tables below are UTF8 literals and normalize() only works in UTF8 databases. On any
  -- other encoding the install would succeed and then silently miscode ß and every accent.
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'cologne_phonetic requires a UTF8 database, found %',
      current_setting('server_encoding');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION cologne_phonetic(input text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $$
DECLARE
  s    text;
  b    bytea;
  n    int;
  ch   text;
  nxt  text;          -- the next character, letter or not; '-' past the end
  prev text := '-';   -- the previous A-Z letter, H included; non-letters do not update it
  code text;
  raw  text := '';    -- step 1 and 2 of the algorithm: one code per letter, adjacent duplicates collapsed
BEGIN
  -- Normalise with translate()/replace() only. upper()/lower() depend on the database collation
  -- (a Turkish collation upper-cases i to İ), and an IMMUTABLE function must not.
  s := translate(normalize(input, NFC), 'äöüÄÖÜ', 'aouAOU');
  s := replace(replace(s, 'ß', 'ss'), 'ẞ', 'ss');
  -- Long s and the ligatures Unicode upper-cases to plain letters (the references do the same).
  s := replace(replace(replace(replace(s, 'ſ', 's'), 'ﬀ', 'ff'), 'ﬁ', 'fi'), 'ﬂ', 'fl');
  s := replace(replace(replace(replace(s, 'ﬃ', 'ffi'), 'ﬄ', 'ffl'), 'ﬅ', 'st'), 'ﬆ', 'st');
  -- Same two tables as tools/generate_corpus.java. Keep them in sync.
  s := translate(s,
    'àáâãåāăąæçćĉċčďđðèéêëēĕėęěĝğġģĥħìíîïĩīĭįıĵķĺļľŀłñńņňòóôõøōŏőœŕŗřśŝşšșţťŧțþùúûũūŭůűųŵýÿŷźżž'
    || 'ÀÁÂÃÅĀĂĄÆÇĆĈĊČĎĐÐÈÉÊËĒĔĖĘĚĜĞĠĢĤĦÌÍÎÏĨĪĬĮİĴĶĹĻĽĿŁÑŃŅŇÒÓÔÕØŌŎŐŒŔŖŘŚŜŞŠȘŢŤŦȚÞÙÚÛŨŪŬŮŰŲŴÝŸŶŹŻŽ',
    'aaaaaaaaacccccdddeeeeeeeeegggghhiiiiiiiiijkllllln' || 'nnnooooooooorrrssssstttttuuuuuuuuuwyyyzzz'
    || 'AAAAAAAAACCCCCDDDEEEEEEEEEGGGGHHIIIIIIIIIJKLLLLLN' || 'NNNOOOOOOOOORRRSSSSSTTTTTUUUUUUUUUWYYYZZZ');
  s := translate(s, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ');

  -- Walk bytes, not characters: substr() on UTF8 text is O(position), get_byte() is O(1). Every
  -- byte of a remaining multi-byte character is >= 0x80, so it is a non-letter both when coded
  -- and when seen by the lookahead, which is exactly how the algorithm treats such characters.
  b := convert_to(s, 'UTF8');
  n := length(b);
  FOR i IN 1..n LOOP
    ch := chr(get_byte(b, i - 1));
    CONTINUE WHEN strpos('ABCDEFGHIJKLMNOPQRSTUVWXYZ', ch) = 0;
    nxt := CASE WHEN i < n THEN chr(get_byte(b, i)) ELSE '-' END;

    code := CASE
      WHEN strpos('AEIJOUY', ch) > 0                          THEN '0'
      WHEN ch = 'B' OR (ch = 'P' AND nxt <> 'H')              THEN '1'
      WHEN ch IN ('D', 'T') AND strpos('CSZ', nxt) = 0        THEN '2'
      WHEN strpos('FPVW', ch) > 0                             THEN '3'
      WHEN strpos('GKQ', ch) > 0                              THEN '4'
      WHEN ch = 'X' AND strpos('CKQ', prev) = 0               THEN '48'
      WHEN ch IN ('S', 'Z')                                   THEN '8'
      WHEN ch = 'C' AND raw = '' THEN                         -- C with no code before it
        CASE WHEN strpos('AHKLOQRUX', nxt) > 0 THEN '4' ELSE '8' END
      WHEN ch = 'C' THEN
        CASE WHEN strpos('SZ', prev) > 0 OR strpos('AHKOQUX', nxt) = 0 THEN '8' ELSE '4' END
      WHEN ch IN ('D', 'T', 'X')                              THEN '8'  -- D/T before C/S/Z; X after C/K/Q
      WHEN ch = 'R'                                           THEN '7'
      WHEN ch = 'L'                                           THEN '5'
      WHEN ch IN ('M', 'N')                                   THEN '6'
      ELSE ''                                                           -- H
    END;

    -- Step 2: a code equal to the previous one is dropped. Because H produces no code at all,
    -- two identical codes separated only by an H are adjacent and collapse; two separated by a
    -- vowel (code 0) are not and both survive step 3. For '48' this only ever drops the '4'.
    raw  := raw || CASE WHEN left(code, 1) = right(raw, 1) THEN substr(code, 2) ELSE code END;
    prev := ch;
  END LOOP;

  -- Step 3: every 0 except a leading one goes.
  RETURN left(raw, 1) || replace(substr(raw, 2), '0', '');
END
$$;
