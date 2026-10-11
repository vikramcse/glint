#!/usr/bin/env python3
"""Builds a themed photo-search benchmark for glint-eval from COCO train2017.

    scripts/coco_theme_bench.py [--theme train] [--out Evals/coco-train] [--themed 200] [--others 60] [--seed 7]

A real library is rarely a random sample: a trip leaves hundreds of photos of the same
trains, beaches or temples. Searching such a library for a detail ("two people near a
train") is where per-query calibration struggles, because the whole library looks like a
match and nothing stands out from it. This corpus reproduces that: about three quarters of
it shows the theme, the rest is unrelated.

Queries come in four kinds, all judged from COCO's annotations:
  - people ("two people near a train"): themed images graded by how many people are
    clearly visible (>= 1% of the image); images whose count is ambiguous (tiny or crowd
    annotations, a near miss on the count) are ignored, neither right nor wrong.
  - with ("a train and a car"): themed images where the other object is visible.
  - caption: one human caption of a themed image; only that image is relevant.
  - negative ("a cat sleeping on a sofa"): every image containing these categories is left
    out of the corpus, so the right answer is no results.

Images and annotations are COCO's (CC licenses per image, annotations CC BY 4.0); they
are never committed. Annotations are cached under ~/Library/Caches/glint-bench.
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
IMAGE_URL = "http://images.cocodataset.org/train2017/{:012d}.jpg"

# Left out of the corpus entirely so searching for them should return nothing.
NEGATIVE_CATEGORIES = ["elephant", "giraffe", "zebra", "pizza", "cake", "cat", "couch", "surfboard"]
NEGATIVE_QUERIES = [
    "elephant", "giraffe eating leaves", "a slice of pizza", "birthday cake with candles", "a cat sleeping on a sofa",
    "surfer riding a wave",
]
THEME_SHARE, VISIBLE, PERSON = 0.10, 0.02, 0.01
CAPTION_QUERIES = 40
# Themed images by visible people, so count queries have enough answers.
PEOPLE_QUOTAS = {0: 0.45, 1: 0.2, 2: 0.2, 3: 0.15}


def annotations():
    folder = CACHE / "annotations"
    if not (folder / "instances_train2017.json").exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        archive = CACHE / "annotations.zip"
        if not archive.exists():
            print("Downloading COCO annotations (253 MB)…")
            urllib.request.urlretrieve(ANNOTATIONS_URL, archive)
        with zipfile.ZipFile(archive) as zf:
            zf.extract("annotations/instances_train2017.json", CACHE)
            zf.extract("annotations/captions_train2017.json", CACHE)
    print("Reading train2017 annotations…")
    instances = json.loads((folder / "instances_train2017.json").read_text())
    captions = json.loads((folder / "captions_train2017.json").read_text())
    return instances, captions


def download(image_id, corpus):
    target = corpus / f"{image_id}.jpg"
    if not target.exists():
        urllib.request.urlretrieve(IMAGE_URL.format(image_id), target)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--theme", default="train")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--themed", type=int, default=200)
    parser.add_argument("--others", type=int, default=60)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    theme = args.theme
    out = args.out or Path(__file__).resolve().parent.parent / f"Evals/coco-{theme}"

    instances, captions = annotations()
    names = {c["id"]: c["name"] for c in instances["categories"]}
    images = {i["id"]: i for i in instances["images"]}
    coverage, people, unclear = {}, {}, set()
    for a in instances["annotations"]:
        image = images[a["image_id"]]
        fraction = a["area"] / (image["width"] * image["height"])
        name = names[a["category_id"]]
        per_image = coverage.setdefault(a["image_id"], {})
        per_image[name] = max(per_image.get(name, 0), fraction)
        if name == "person":
            if a.get("iscrowd") or fraction < PERSON:
                unclear.add(a["image_id"])
            else:
                people[a["image_id"]] = people.get(a["image_id"], 0) + 1

    negatives = set(NEGATIVE_CATEGORIES)
    usable = {i for i, cats in coverage.items() if not negatives & cats.keys()}
    themed_pool = sorted(i for i in usable if coverage[i].get(theme, 0) >= THEME_SHARE)
    other_pool = sorted(i for i in usable if theme not in coverage[i])
    rng = random.Random(args.seed)

    # Themed images with a clear person count, stratified by it.
    themed = []
    for count, share in PEOPLE_QUOTAS.items():
        group = [i for i in themed_pool if i not in unclear and min(people.get(i, 0), 3) == count]
        themed += rng.sample(group, min(len(group), round(args.themed * share)))
    others = rng.sample(other_pool, args.others)
    chosen = sorted(themed + others)

    corpus = out / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {len(chosen)} images ({len(themed)} {theme}, {len(others)} other)…")
    with ThreadPoolExecutor(max_workers=16) as pool:
        list(pool.map(lambda i: download(i, corpus), chosen))

    def file(i):
        return f"{i}.jpg"

    def count(i):
        return people.get(i, 0)

    queries = []

    def people_query(qid, text, grade):
        relevant, ignored = {}, []
        for i in themed:
            g = grade(count(i))
            if g is None:
                ignored.append(file(i))
            elif g > 0:
                relevant[file(i)] = g
        queries.append({"id": qid, "text": text, "relevant": relevant, "ignored": ignored})

    people_query(f"people-two-{theme}", f"two people near a {theme}", lambda n: 2 if n == 2 else (None if n in (1, 3) else 0))
    people_query(f"people-one-{theme}", f"a person standing next to a {theme}", lambda n: 2 if n == 1 else (None if n == 2 else 0))
    people_query(f"people-group-{theme}", f"a group of people by a {theme}", lambda n: 2 if n >= 3 else (None if n == 2 else 0))
    people_query(f"people-none-{theme}", f"a {theme} with nobody around", lambda n: 2 if n == 0 else 0)

    for name in sorted(set(names.values()) - negatives - {theme, "person"}):
        relevant = {file(i): 2 for i in themed if coverage[i].get(name, 0) >= VISIBLE}
        if len(relevant) >= 3:
            ignored = [file(i) for i in themed if 0 < coverage[i].get(name, 0) < VISIBLE]
            queries.append({"id": f"with-{name.replace(' ', '-')}", "text": f"a {theme} and a {name}", "relevant": relevant,
                            "ignored": ignored})

    by_image = {}
    for c in captions["annotations"]:
        by_image.setdefault(c["image_id"], []).append(c["caption"].strip().rstrip("."))
    for i in rng.sample(themed, min(CAPTION_QUERIES, len(themed))):
        queries.append({"id": f"cap-{i}", "text": sorted(by_image[i])[0], "relevant": {file(i): 2}})

    for text in NEGATIVE_QUERIES:
        queries.append({"id": f"none-{text.replace(' ', '-')}", "text": text, "relevant": {}})

    (out / "queries.json").write_text(json.dumps({"queries": queries}, indent=1))
    kinds = {k: sum(q["id"].startswith(k) for q in queries) for k in ("people-", "with-", "cap-", "none-")}
    print(f"Wrote {len(queries)} queries to {out / 'queries.json'}: {kinds}")


if __name__ == "__main__":
    main()
