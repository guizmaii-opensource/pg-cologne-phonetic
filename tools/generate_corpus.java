// Corpus generator, reference #1: Apache Commons Codec.
//
// Run through tools/generate_corpus.sh, which fetches the codec jar, runs the Rust reference
// and calls this file twice:
//
//   java -cp <codec.jar> tools/generate_corpus.java fold   tools/inputs.txt
//       prints every input after this repo's accent fold (§5 of the brief), one per line.
//       The Rust reference consumes that output.
//
//   java -cp <codec.jar> tools/generate_corpus.java corpus tools/inputs.txt <rphonetic codes> tools/decisions.txt
//       prints test/corpus.json. Fails if the two references disagree on an input that has no
//       recorded decision in tools/decisions.txt.
//
// Both references only fold Ä/Ö/Ü/ß. Every other accented letter (é, ç, ø, ł, ...) is dropped by
// them, which is not what this function does: it folds them to their unaccented ASCII letter.
// The fold below is therefore applied *before* handing an input to either reference. It must
// stay identical to the translate() table in sql/cologne_phonetic.sql. ẞ (capital sharp s) is
// mapped to ß so the references' own ß handling covers it. Input is NFC-normalised first, like the SQL.

import org.apache.commons.codec.language.ColognePhonetic;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class generate_corpus {

    // Same two strings as sql/cologne_phonetic.sql. Keep them in sync: every character of FOLD_FROM is
    // also a single-character case in tools/inputs.txt, so a fold missing on the SQL side fails the tests.
    static final String FOLD_FROM =
        "àáâãåāăąæçćĉċčďđðèéêëēĕėęěĝğġģĥħìíîïĩīĭįıĵķĺļľŀłñńņňòóôõøōŏőœŕŗřśŝşšșţťŧțþùúûũūŭůűųŵýÿŷźżž"
      + "ÀÁÂÃÅĀĂĄÆÇĆĈĊČĎĐÐÈÉÊËĒĔĖĘĚĜĞĠĢĤĦÌÍÎÏĨĪĬĮİĴĶĹĻĽĿŁÑŃŅŇÒÓÔÕØŌŎŐŒŔŖŘŚŜŞŠȘŢŤŦȚÞÙÚÛŨŪŬŮŰŲŴÝŸŶŹŻŽẞ";
    static final String FOLD_TO =
        "aaaaaaaaacccccdddeeeeeeeeegggghhiiiiiiiiijkllllln" + "nnnooooooooorrrssssstttttuuuuuuuuuwyyyzzz"
      + "AAAAAAAAACCCCCDDDEEEEEEEEEGGGGHHIIIIIIIIIJKLLLLLN" + "NNNOOOOOOOOORRRSSSSSTTTTTUUUUUUUUUWYYYZZZß";

    static String fold(String s) {
        // NFC first, as the SQL does with normalize(input, NFC): a decomposed é (e + U+0301) would
        // otherwise reach the references as a plain e followed by a non-letter the lookahead can see.
        s = Normalizer.normalize(s, Normalizer.Form.NFC);
        // Long s and ligatures, as in the SQL. The references would upper-case them to ASCII anyway;
        // this keeps the fold explicit and identical on both sides.
        s = s.replace("ſ", "s").replace("ﬀ", "ff").replace("ﬁ", "fi").replace("ﬂ", "fl")
             .replace("ﬃ", "ffi").replace("ﬄ", "ffl").replace("ﬅ", "st").replace("ﬆ", "st");
        StringBuilder sb = new StringBuilder(s.length());
        s.codePoints().forEach(cp -> {
            int i = FOLD_FROM.indexOf(cp);
            sb.appendCodePoint(i < 0 ? cp : FOLD_TO.codePointAt(i));
        });
        return sb.toString();
    }

    static List<String> readLines(String path) throws IOException {
        // Files.readAllLines strips the trailing newline of the last line but keeps empty lines.
        return Files.readAllLines(Path.of(path), StandardCharsets.UTF_8);
    }

    static String json(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
                }
            }
        }
        return sb.append('"').toString();
    }

    public static void main(String[] args) throws IOException {
        if (args.length < 2) usage();
        List<String> inputs = readLines(args[1]);
        var out = new StringBuilder();

        switch (args[0]) {
            case "fold" -> {
                if (FOLD_FROM.codePointCount(0, FOLD_FROM.length()) != FOLD_TO.codePointCount(0, FOLD_TO.length())) {
                    throw new IllegalStateException("FOLD_FROM and FOLD_TO differ in length");
                }
                for (String in : inputs) out.append(fold(in)).append('\n');
            }
            case "corpus" -> {
                if (args.length != 4) usage();
                List<String> rphonetic = readLines(args[2]);
                if (rphonetic.size() != inputs.size()) {
                    throw new IllegalStateException("rphonetic produced " + rphonetic.size()
                        + " codes for " + inputs.size() + " inputs");
                }
                Map<String, String[]> decisions = readDecisions(args[3]);
                var codec = new ColognePhonetic();
                var unresolved = new ArrayList<String>();
                var seen = new HashMap<String, Integer>();

                out.append("[\n");
                for (int i = 0; i < inputs.size(); i++) {
                    String input = inputs.get(i);
                    if (seen.put(input, i) != null) {
                        throw new IllegalStateException("duplicate input at line " + (i + 1) + ": " + json(input));
                    }
                    String commons = codec.colognePhonetic(fold(input));
                    String rp = rphonetic.get(i);
                    if (i > 0) out.append(",\n");
                    out.append("  {\"input\": ").append(json(input));
                    if (commons.equals(rp)) {
                        out.append(", \"expected\": ").append(json(commons));
                    } else {
                        String[] d = decisions.get(input);
                        if (d == null) {
                            unresolved.add(json(input) + "  commons=" + commons + "  rphonetic=" + rp);
                            continue;
                        }
                        String expected = switch (d[0]) {
                            case "commons" -> commons;
                            case "rphonetic" -> rp;
                            default -> throw new IllegalStateException("decision for " + json(input)
                                + " must be 'commons' or 'rphonetic', got " + d[0]);
                        };
                        out.append(", \"expected\": ").append(json(expected))
                           .append(",\n   \"commons\": ").append(json(commons))
                           .append(", \"rphonetic\": ").append(json(rp))
                           .append(", \"chosen\": ").append(json(d[0]))
                           .append(",\n   \"why\": ").append(json(d[1]));
                    }
                    out.append("}");
                }
                out.append("\n]\n");

                if (!unresolved.isEmpty()) {
                    System.err.println("The two references disagree and tools/decisions.txt has no entry for:");
                    unresolved.forEach(u -> System.err.println("  " + u));
                    System.exit(1);
                }
                for (String k : decisions.keySet()) {
                    if (!seen.containsKey(k)) {
                        System.err.println("tools/decisions.txt names an input that is not in tools/inputs.txt: " + json(k));
                        System.exit(1);
                    }
                }
            }
            default -> usage();
        }
        System.out.print(out);
    }

    // decisions.txt: blank lines and lines starting with '#' are ignored. Every other line is
    //   <input> TAB <commons|rphonetic> TAB <why>
    static Map<String, String[]> readDecisions(String path) throws IOException {
        var m = new HashMap<String, String[]>();
        for (String line : readLines(path)) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] p = line.split("\t", 3);
            if (p.length != 3) throw new IllegalStateException("bad decisions line: " + json(line));
            m.put(p[0], new String[] {p[1], p[2]});
        }
        return m;
    }

    static void usage() {
        System.err.println("usage: generate_corpus.java fold <inputs.txt>");
        System.err.println("       generate_corpus.java corpus <inputs.txt> <rphonetic codes> <decisions.txt>");
        System.exit(2);
    }
}
