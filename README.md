# pg-cologne-phonetic

Kölner Phonetik (Cologne phonetics) as a plain, immutable PostgreSQL function. Phonetic matching
for German names, which `fuzzystrmatch` does not provide.

```sql
SELECT cologne_phonetic('Müller'), cologne_phonetic('Mueller'), cologne_phonetic('Meyer'), cologne_phonetic('Maier');
--  657 | 657 | 67 | 67
```

## What it is

[Kölner Phonetik](https://de.wikipedia.org/wiki/K%C3%B6lner_Phonetik) (Hans Joachim Postel, 1969)
maps a word to a string of digits so that words which sound alike in German share a code. It is
the German-language counterpart of Soundex. PostgreSQL's `fuzzystrmatch` ships `soundex`,
`metaphone`, `dmetaphone` and `daitch_mokotoff`, all tuned for English; none of them handles
`Schmidt`/`Schmitt` or `Meyer`/`Maier`/`Mayr` well.

## Why a function and not an extension

Managed PostgreSQL (RDS, Cloud SQL, Azure Database) gives no filesystem access, so a compiled
extension cannot be installed. A function written in PL/pgSQL is just SQL text and can. That is the
whole reason this repo takes this form. On self-hosted PostgreSQL you could write it in C and get
a faster result; on managed PostgreSQL you cannot, and this is the alternative.

## Requirements

- **PostgreSQL 18 or later.** The install file refuses to run on anything older:

  ```
  ERROR:  cologne_phonetic requires PostgreSQL 18 or later, found 17.11
  ```

  Nothing in the function actually needs 18. The floor is a scope decision: one version to write
  for, one to test, one to reason about. If you lower it, change the guard at the top of
  `sql/cologne_phonetic.sql` and widen the CI matrix in the same commit.
- A UTF8 database. The install file refuses any other server encoding, because on `SQL_ASCII` or
  `LATIN1` it would install fine and then silently miscode `ß` and every accent.
- `plpgsql`, which every PostgreSQL database has.

## Install

Apply [`sql/cologne_phonetic.sql`](sql/cologne_phonetic.sql) with whatever migration tool you
already use, or directly:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/cologne_phonetic.sql
```

It creates one function in the current schema:

```sql
cologne_phonetic(input text) RETURNS text
  LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
```

## Use

Compute the code once, when a row is written, and store it. Lookups then compare stored codes:

```sql
ALTER TABLE people ADD COLUMN name_sounds text
    GENERATED ALWAYS AS (cologne_phonetic(full_name)) STORED;
CREATE INDEX ON people (name_sounds);

SELECT * FROM people WHERE name_sounds = cologne_phonetic('Mueller');
```

An expression index `CREATE INDEX ON people (cologne_phonetic(full_name))` works too.

## Behaviour

| Input | Output |
|:--|:--|
| `NULL` | `NULL` |
| `''` | `''` |
| Anything with no codeable letter (`'123'`, `'...'`, `'Пушкин'`, `'北京'`) | `''` |
| Anything else | a string of digits |

- **Case is irrelevant.** `müller`, `Müller` and `MÜLLER` give the same code.
- **Umlauts and ß fold before coding.** `ä`→`a`, `ö`→`o`, `ü`→`u`, `ß`→`ss`. The accented letters
  of the Latin-1 Supplement and Latin Extended-A blocks fold to their base letter (`é`→`e`, `ç`→`c`,
  `ø`→`o`, `ł`→`l`), so `François` and `Francois` match. Long s (`ſ`) and the `ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ`
  ligatures found in OCR'd text fold to their letters. Letters outside those blocks (Vietnamese
  `ơ`, `ạ`; Latin Extended Additional `ṇ`, `ṣ`) are not folded and code as non-letters.
- **Input is NFC-normalised first.** `u` + U+0308 codes exactly like `ü`, and a decomposed `ç`
  cannot land in the lookahead of the letter before it. Without this, `François` in NFD form would
  code differently from the same name in NFC form.
- **Non-letters are not coded.** `O'Brien` and `OBrien` give the same code, and so do
  `Meyer-Schmidt` and `MeyerSchmidt`. A non-letter is still visible to the one-character lookahead
  some rules use, exactly as in the reference implementations: in `St-Cyr` the `T` sees `-` and
  codes as `2`, in `StCyr` it sees `C` and codes as `8`.
- **Never raises.** Punctuation, non-Latin script, emoji, a 14 000-character string: all return a
  value. An error inside a generated column's expression would turn a bad name into a failed
  insert.
- **Collation-independent.** The function uses only `normalize()`, `translate()` and `replace()`
  to normalise, never `upper()`/`lower()` (a `tr-TR` collation upper-cases `i` to `İ`), so the
  result is the same in a `C`, `de-DE` or `tr-TR` database. CI runs the test suite under all
  three.

## The corpus is the specification

Prose descriptions of Kölner Phonetik leave edge cases open, and real implementations disagree on
exactly those. This function was therefore not written from a description but against
[`test/corpus.json`](test/corpus.json): more than 600 inputs with the code produced by two independent
implementations,

- **Apache Commons Codec** 1.22.1, `org.apache.commons.codec.language.ColognePhonetic`
  ([`tools/generate_corpus.java`](tools/generate_corpus.java)), and
- the Rust **`rphonetic`** crate 3.1.0 ([`tools/rphonetic`](tools/rphonetic)).

Where both agree, the value is settled. Where they disagree, the case stays in the corpus with both
values, the one chosen, and why. Every disagreement so far comes from a single question: what
happens to two identical codes separated by a vowel or by an `H`. The algorithm's three steps are

1. code every letter with the table,
2. collapse runs of identical adjacent codes,
3. drop every `0` except a leading one,

so `Hoffmann` is `0366` (the two `6`s are separated by a `0` at step 2 and both survive) while
`Mülhler` is `657` (`H` has no code at all, so the two `5`s are adjacent and collapse). Commons
Codec 1.22.0 changed its behaviour ([CODEC-317](https://issues.apache.org/jira/browse/CODEC-317))
and now collapses both (`Hoffmann` → `036`); rphonetic, a port of Commons ≤ 1.21, collapses
neither (`Mülhler` → `6557`). This function follows the three steps, which is also what Commons
Codec did for fifteen years and what the published examples for the algorithm show. Each decision
is recorded per input in [`tools/decisions.txt`](tools/decisions.txt).

The references only fold `Ä`, `Ö`, `Ü` and `ß`; they drop every other accented letter. The NFC
normalisation and the fold of other accents described above are this repo's rules, applied in the
generator before an input reaches either reference, so the expected values still come from the
references. Every character of the fold table is also a single-character corpus case, which keeps
the SQL table and the generator table in sync.

### Regenerating the corpus

```sh
tools/generate_corpus.sh    # needs java 17+, cargo, curl
```

Add inputs to `tools/inputs.txt`. If the two references disagree on a new input the script stops
and lists it; record the choice in `tools/decisions.txt` and run it again. CI regenerates the corpus
and fails if the committed file differs.

## Tests

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f test/run_tests.sql   # from the repo root, scratch database
```

`test/run_tests.sql` installs the function inside a transaction, asserts every corpus case (printing
input, expected and actual for each mismatch), then checks the contract: `NULL` handling, the
`IMMUTABLE`/`PARALLEL SAFE`/`STRICT` flags, case-insensitivity of every corpus input, the
never-raises rule, and real use in a `GENERATED ALWAYS ... STORED` column with an index. It rolls
back at the end. CI runs it against a PostgreSQL 18 container, and separately checks that the
install file is rejected by PostgreSQL 17 with the intended message.

## Performance

The function runs once per row at write time and once per query term at read time, never once per
row of a query, so it does not need to be fast. Measured on PostgreSQL 18 in Docker (2 CPUs, Apple
M3 Pro host):

| Operation | Time |
|:--|:--|
| One call, 19-character name (`Müller-Lüdenscheidt`) | ~25 µs |
| One call, 200-character word | ~240 µs |
| One call, 56 000-character string | 1.8 s |
| `CREATE INDEX ON t (cologne_phonetic(name))`, 1 000 000 rows | 10 s |
| `ALTER TABLE t ADD COLUMN ... GENERATED ALWAYS AS (cologne_phonetic(name)) STORED`, 1 000 000 rows | 30 s (includes the table rewrite) |

Time is linear in the input length: the loop walks the UTF8 bytes with `get_byte()`, which is
O(1), rather than characters with `substr()`, which is O(position) on UTF8 text.

## Licence

[Apache License 2.0](LICENSE).
