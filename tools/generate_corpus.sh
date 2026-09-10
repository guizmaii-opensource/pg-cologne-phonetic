#!/usr/bin/env sh
# Regenerates test/corpus.json from tools/inputs.txt using both references.
# Needs: java 17+, cargo, curl. Run from anywhere; paths are resolved relative to this script.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cache="$here/.cache"
codec_version=1.22.1
jar="$cache/commons-codec-$codec_version.jar"

mkdir -p "$cache"
if [ ! -f "$jar" ]; then
  curl -sSf -o "$jar" \
    "https://repo1.maven.org/maven2/commons-codec/commons-codec/$codec_version/commons-codec-$codec_version.jar"
fi

java -cp "$jar" "$here/generate_corpus.java" fold "$here/inputs.txt" > "$cache/folded.txt"
(cd "$here/rphonetic" && cargo run --quiet --release -- "$cache/folded.txt") > "$cache/rphonetic.txt"
# Written to a temp file first so a failed run (an undecided disagreement) leaves the committed corpus intact.
java -cp "$jar" "$here/generate_corpus.java" corpus "$here/inputs.txt" "$cache/rphonetic.txt" "$here/decisions.txt" \
  > "$cache/corpus.json.tmp"
mv "$cache/corpus.json.tmp" "$here/../test/corpus.json"
echo "wrote $(grep -c '"input"' "$here/../test/corpus.json") cases to test/corpus.json"
