"""Writes Hugging Face tokenizer ids for hard cases, the ground truth for EG2Tokenizer.

    python scripts/model/make_tokenizer_fixtures.py <checkpoint>/tokenizer.json

Needs `pip install tokenizers`. Writes Tests/GlintEmbeddingTests/Fixtures/tokenizer_cases.json.
"""

import json
import sys
from pathlib import Path

from tokenizers import Tokenizer

CASES = [
    "", " ", "  ", "   leading", "trailing   ", "a", "aaaaaaaaaaaaaaaa", "\n\n\n\t\t  \n",
    "the receipt from the hotel in Goa", "task: search result | query: car",
    "Grüße aus Zürich – café naïve façade", "東京タワーの夜景", "서울의 봄", "مرحبا بالعالم", "नमस्ते दुनिया",
    "emoji 👩‍👩‍👧‍👦 🇮🇳 🧑🏽‍💻 ❤️‍🔥", "zero​width﻿joiners", "math ∑∫√∞ ≠ ≤",
    "control \u0001\u0007\u007f", "\U0010ffff",
    "<eos>", "a<eos>b", "<bos><eos><pad>", "<|image|><image|><|image>", '<unknown> <0x41> <|"|>', "<<eos>>", "<",
    "func scan(_ matrix: VectorMatrix) -> [Float] { return [] } // x += 1",
    "https://example.com/path?q=1&r=2#frag", "1234567890 3.14159 -42 1e10",
    # A space before a combining mark is still a space (one grapheme, two scalars).
    "combining é ä́ ́start", "x ́", " ̈̈",
    # Canonically equivalent but distinct tokens must stay distinct.
    "AK3", "K", "K", "café", "café", "Ångström Ångström",
    # Byte-order marks inside text.
    "﻿", "﻿﻿", "a﻿﻿b",
]


def main():
    tokenizer = Tokenizer.from_file(sys.argv[1])
    rows = [{"text": text, "ids": tokenizer.encode(text, add_special_tokens=False).ids} for text in CASES]
    out = Path(__file__).resolve().parents[2] / "Tests/GlintEmbeddingTests/Fixtures/tokenizer_cases.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(rows, ensure_ascii=True, indent=1) + "\n")
    print(f"Wrote {len(rows)} cases to {out}")


if __name__ == "__main__":
    main()
