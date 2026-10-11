#!/usr/bin/env python3
"""Builds a document-search benchmark for glint-eval from BEIR SciFact.

    scripts/beir_bench.py [--out Evals/scifact]

Writes DIR/corpus/<title>.txt (the abstract only, so the title reaches Glint through the
file name) and DIR/queries.json (gitignored), then run:

    glint-eval run Evals/scifact --model gemma --model-dir <checkpoint>

Queries are SciFact's 300 test claims, each with the abstracts that support or refute it,
plus off-topic negative queries the biomedical corpus cannot answer. SciFact is CC BY-NC
2.0: use it for evaluation only; it is cached under ~/Library/Caches/glint-bench and never
committed.
"""

import argparse
import csv
import io
import json
import re
import urllib.request
import zipfile
from pathlib import Path

CACHE = Path.home() / "Library/Caches/glint-bench/beir"
URL = "https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/scifact.zip"
NEGATIVES = [
    "guest wifi password", "birthday party invitation", "car insurance renewal", "football match score",
    "hotel booking in Goa", "javascript promise error", "wedding photos", "quarterly sales deck",
    "recipe for pasta carbonara", "piano lesson schedule",
]


def dataset():
    folder = CACHE / "scifact"
    if not (folder / "corpus.jsonl").exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print("Downloading SciFact (2.8 MB)…")
        with urllib.request.urlopen(URL) as response:
            zipfile.ZipFile(io.BytesIO(response.read())).extractall(CACHE)
    corpus = [json.loads(line) for line in (folder / "corpus.jsonl").open(encoding="utf-8")]
    queries = {q["_id"]: q["text"] for q in map(json.loads, (folder / "queries.jsonl").open(encoding="utf-8"))}
    qrels = {}
    with (folder / "qrels/test.tsv").open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            qrels.setdefault(row["query-id"], {})[row["corpus-id"]] = int(row["score"])
    return corpus, queries, qrels


def file_name(title, doc_id, used):
    name = re.sub(r"[/:\\\x00-\x1f]", " ", title).strip().rstrip(".")
    name = re.sub(r"\s+", " ", name)[:120].strip() or doc_id
    if name.lower() in used:
        name = f"{name} ({doc_id})"
    used.add(name.lower())
    return name + ".txt"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "Evals/scifact")
    args = parser.parse_args()

    corpus, queries, qrels = dataset()
    out = args.out / "corpus"
    out.mkdir(parents=True, exist_ok=True)
    used, names = set(), {}
    for doc in corpus:
        names[doc["_id"]] = file_name(doc["title"], doc["_id"], used)
        (out / names[doc["_id"]]).write_text(doc["text"], encoding="utf-8")

    rows = [
        {"id": f"claim-{qid}", "text": queries[qid], "relevant": {names[d]: 2 for d, score in rel.items() if score > 0}}
        for qid, rel in sorted(qrels.items(), key=lambda item: int(item[0]))
    ]
    rows += [{"id": "none-" + text.replace(" ", "-"), "text": text, "relevant": {}} for text in NEGATIVES]
    (args.out / "queries.json").write_text(json.dumps({"queries": rows}, indent=1), encoding="utf-8")
    print(f"Wrote {len(corpus)} documents and {len(rows)} queries to {args.out}")


if __name__ == "__main__":
    main()
