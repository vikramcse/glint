#!/usr/bin/env python3
"""Builds a mixed-media benchmark for glint-eval from the COCO and SciFact benchmarks.

    scripts/coco_bench.py && scripts/beir_bench.py      # once
    scripts/mixed_bench.py [--out Evals/mixed] [--photos 300] [--papers 1500] [--seed 7]

A real library mixes photos and documents in one index, and the two score differently:
text-to-text cosines run higher than text-to-image, so a cutoff calibrated over the whole
library is loose for documents and tight for photos. This corpus links photos from
Evals/coco and abstracts from Evals/scifact into one folder and keeps their queries. The
answer to every query lives in one modality, so a document returned for a photo query (or
the reverse) counts against precision.

Queries: COCO captions and categories, SciFact claims, and both sets' negatives.
"""

import argparse
import json
import os
import random
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent / "Evals"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=root / "mixed")
    parser.add_argument("--photos", type=int, default=300)
    parser.add_argument("--papers", type=int, default=1500)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)

    coco = json.loads((root / "coco/queries.json").read_text())["queries"]
    scifact = json.loads((root / "scifact/queries.json").read_text())["queries"]

    # Photos: every image some kept caption query needs, filled up with random ones.
    captions = [q for q in coco if q["id"].startswith("cap-")]
    kept_captions = rng.sample(captions, min(60, len(captions)))
    photos = {p for q in kept_captions for p in q["relevant"]}
    others = sorted(set(os.listdir(root / "coco/corpus")) - photos)
    photos |= set(rng.sample(others, max(0, args.photos - len(photos))))

    # Papers: every abstract some kept claim needs, filled up with random ones.
    claims = [q for q in scifact if q["relevant"]]
    kept_claims = rng.sample(claims, min(100, len(claims)))
    papers = {p for q in kept_claims for p in q["relevant"]}
    others = sorted(set(os.listdir(root / "scifact/corpus")) - papers)
    papers |= set(rng.sample(others, max(0, args.papers - len(papers))))

    corpus = args.out / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    for existing in corpus.iterdir():
        existing.unlink()
    for name in photos:
        os.link(root / "coco/corpus" / name, corpus / name)
    for name in papers:
        os.link(root / "scifact/corpus" / name, corpus / name)

    def restrict(query, present):
        relevant = {p: g for p, g in query["relevant"].items() if p in present}
        ignored = [p for p in query.get("ignored", []) if p in present]
        return {**query, "relevant": relevant, "ignored": ignored} if ignored else {**{k: v for k, v in query.items() if k != "ignored"}, "relevant": relevant}

    queries = [restrict(q, photos) for q in kept_captions]
    categories = [restrict(q, photos) for q in coco if q["id"].startswith("cat-")]
    queries += [q for q in categories if len(q["relevant"]) >= 3][:30]
    queries += [restrict(q, papers) for q in kept_claims]
    queries += [q for q in coco + scifact if not q["relevant"]]
    for q in queries:
        q["mustPass"] = False
    (args.out / "queries.json").write_text(json.dumps({"queries": queries}, indent=1))
    kinds = {k: sum(q["id"].startswith(k) for q in queries) for k in ("cap-", "cat-", "claim-", "none-")}
    print(f"Linked {len(photos)} photos and {len(papers)} papers into {corpus}; wrote {len(queries)} queries: {kinds}")


if __name__ == "__main__":
    main()
