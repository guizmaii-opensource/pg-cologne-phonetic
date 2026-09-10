//! Corpus generator, reference #2: the `rphonetic` crate.
//!
//! Reads one (already accent-folded, see tools/generate_corpus.java) input per line from the
//! file given as the only argument and prints one Cologne code per line, in the same order.
//! Codes are printed alone, not next to their input, because inputs may contain tabs.
use rphonetic::{Cologne, Encoder};
use std::io::Write;

fn main() {
    let path = std::env::args().nth(1).expect("usage: rphonetic-corpus <folded inputs file>");
    let text = std::fs::read_to_string(&path).expect("cannot read inputs");
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for line in text.lines() {
        writeln!(out, "{}", Cologne.encode(line)).unwrap();
    }
}
