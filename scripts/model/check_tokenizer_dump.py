"""Checks Glint's compact tokenizer against Hugging Face's Rust tokenizer.

    GLINT_EG2_DIR=<checkpoint> GLINT_TOKENIZER_DUMP=/tmp/ids.json swift test --filter EG2TokenizerParity
    python scripts/model/check_tokenizer_dump.py <checkpoint>/tokenizer.json /tmp/ids.json

Needs `pip install tokenizers`. Exits non-zero on any mismatch.
"""

import json
import sys

from tokenizers import Tokenizer


def main():
    tokenizer = Tokenizer.from_file(sys.argv[1])
    rows = json.load(open(sys.argv[2], encoding="utf-8"))
    mismatches = 0
    for row in rows:
        expected = tokenizer.encode(row["text"], add_special_tokens=False).ids
        if expected != row["ids"]:
            mismatches += 1
            if mismatches <= 5:
                print(repr(row["text"][:80]), "\n  hf    ", expected[:20], "\n  glint ", row["ids"][:20])
    print(f"Checked {len(rows)} texts against Hugging Face tokenizers: {mismatches} mismatches")
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
