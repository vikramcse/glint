#!/usr/bin/env python3
"""Builds a photo-search benchmark for glint-eval from COCO val2017.

    scripts/coco_bench.py [--out Evals/coco] [--images 600] [--seed 7]

Writes DIR/corpus/*.jpg and DIR/queries.json (gitignored), then run:

    glint-eval run Evals/coco --model gemma --model-dir <checkpoint>

Queries come in three kinds:
  - category ("car", "dog"): every image where the object is clearly visible is relevant
    (grade 2 when it covers >= 10% of the image, 1 when >= 2%); images where it is
    smaller are ignored, neither right nor wrong.
  - caption: one human caption; only its own image is relevant.
  - negative ("elephant"): every image containing these categories is left out of the
    corpus, so the right answer is no results.

Images and annotations are COCO's (CC licenses per image, annotations CC BY 4.0); they
are never committed. Annotations are cached under ~/Library/Caches/glint-bench; the corpus
cannot live there because Glint's default exclusions skip Caches folders.
"""

import argparse
import json
import random
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CACHE = Path.home() / "Library/Caches/glint-bench/coco"
ANNOTATIONS_URL = "http://images.cocodataset.org/annotations/annotations_trainval2017.zip"
IMAGE_URL = "http://images.cocodataset.org/val2017/{:012d}.jpg"

# Left out of the corpus entirely so searching for them should return nothing.
NEGATIVE_CATEGORIES = ["elephant", "giraffe", "zebra", "bear", "airplane", "pizza", "surfboard", "kite"]
NEGATIVE_PHRASES = ["a herd of elephants", "giraffe eating leaves", "a slice of pizza", "plane taking off"]
# Too broad to judge as a category query (nearly every image has one).
SKIPPED_CATEGORIES = {"person"}
CAPTION_QUERIES = 100
STRONG, VISIBLE = 0.10, 0.02


def annotations():
    folder = CACHE / "annotations"
    if not (folder / "instances_val2017.json").exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        archive = CACHE / "annotations.zip"
        if not archive.exists():
            print("Downloading COCO annotations (253 MB)…")
            urllib.request.urlretrieve(ANNOTATIONS_URL, archive)
        with zipfile.ZipFile(archive) as zf:
            zf.extract("annotations/instances_val2017.json", CACHE)
            zf.extract("annotations/captions_val2017.json", CACHE)
    instances = json.loads((folder / "instances_val2017.json").read_text())
    captions = json.loads((folder / "captions_val2017.json").read_text())
    return instances, captions


def download(image_id, corpus):
    target = corpus / f"{image_id}.jpg"
    if not target.exists():
        urllib.request.urlretrieve(IMAGE_URL.format(image_id), target)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "Evals/coco")
    parser.add_argument("--images", type=int, default=600)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    instances, captions = annotations()
    names = {c["id"]: c["name"] for c in instances["categories"]}
    images = {i["id"]: i for i in instances["images"]}
    # Largest area fraction of each category per image.
    coverage = {}
    for a in instances["annotations"]:
        image = images[a["image_id"]]
        fraction = a["area"] / (image["width"] * image["height"])
        per_image = coverage.setdefault(a["image_id"], {})
        name = names[a["category_id"]]
        per_image[name] = max(per_image.get(name, 0), fraction)

    negatives = set(NEGATIVE_CATEGORIES)
    pool = sorted(i for i, cats in coverage.items() if not negatives & cats.keys())
    rng = random.Random(args.seed)
    chosen = sorted(rng.sample(pool, args.images))

    corpus = args.out / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {len(chosen)} images…")
    with ThreadPoolExecutor(max_workers=16) as pool_:
        list(pool_.map(lambda i: download(i, corpus), chosen))

    queries = []
    for name in sorted(set(names.values()) - negatives - SKIPPED_CATEGORIES):
        relevant, ignored = {}, []
        for image_id in chosen:
            fraction = coverage[image_id].get(name, 0)
            if fraction >= STRONG:
                relevant[f"{image_id}.jpg"] = 2
            elif fraction >= VISIBLE:
                relevant[f"{image_id}.jpg"] = 1
            elif fraction > 0:
                ignored.append(f"{image_id}.jpg")
        if len(relevant) >= 3:
            queries.append({"id": f"cat-{name.replace(' ', '-')}", "text": name, "relevant": relevant, "ignored": ignored})

    by_image = {}
    for c in captions["annotations"]:
        by_image.setdefault(c["image_id"], []).append(c["caption"].strip().rstrip("."))
    for image_id in rng.sample(chosen, CAPTION_QUERIES):
        text = sorted(by_image[image_id])[0]
        queries.append({"id": f"cap-{image_id}", "text": text, "relevant": {f"{image_id}.jpg": 2}})

    for text in NEGATIVE_CATEGORIES + NEGATIVE_PHRASES:
        queries.append({"id": f"none-{text.replace(' ', '-')}", "text": text, "relevant": {}})

    (args.out / "queries.json").write_text(json.dumps({"queries": queries}, indent=1))
    kinds = {k: sum(q["id"].startswith(k) for q in queries) for k in ("cat-", "cap-", "none-")}
    print(f"Wrote {len(queries)} queries to {args.out / 'queries.json'}: {kinds}")


if __name__ == "__main__":
    main()
