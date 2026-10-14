#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyarrow"]
# ///
"""Builds a natural-language benchmark over every kind Glint searches: photos, videos, audio
and text documents in one index.

    scripts/coco_bench.py && scripts/beir_bench.py      # once
    scripts/media_bench.py [--out Evals/media] [--photos 300] [--papers 500] [--videos 200]
                           [--audio 200] [--queries 80] [--seed 7]

Then run:

    glint-eval run Evals/media --model gemma --model-dir <checkpoint>

Sources (each caption written by a person describing that one file):
  - photos: Evals/coco (COCO val2017), its captions and object categories.
  - text: Evals/scifact (BEIR SciFact abstracts), its claims.
  - videos: MSR-VTT test 1k-A, 10–30 s YouTube clips, one standard caption each. Only the
    clips needed are fetched from the 2.2 GB archive, by HTTP range requests.
  - audio: Clotho evaluation split, 15–30 s Freesound recordings, five captions each. Files
    are renamed rec-NNNN.wav, since Clotho's names ("Rain on tin roof.wav") give the answer
    away to filename matching; real recordings are named by the device.

A caption query counts only its own file as relevant, so a second clip that fits the
caption equally well scores as a miss. Video and audio captions are often generic ("a man is
talking"), so read their numbers as a floor and compare builds, not absolute values.

Negative queries ("a herd of elephants") have no answer in any kind: COCO already leaves
those categories out, and every clip whose captions mention them is dropped here.

MSR-VTT (research use) and Clotho (Freesound clips under CC licenses per clip; captions
Tampere University, research use) are cached under ~/Library/Caches/glint-bench and never
committed. The corpus cannot live there because Glint's default exclusions skip Caches.
"""

import argparse
import io
import json
import os
import random
import re
import struct
import urllib.request
import zipfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CACHE = Path.home() / "Library/Caches/glint-bench"
MSRVTT = "https://huggingface.co/datasets/friedrichor/MSR-VTT/resolve/main/"
CLOTHO = "https://huggingface.co/datasets/gijs/clotho/resolve/main/data/test-00000-of-00002.parquet"

# Queries with no answer in the corpus, and the words that drop a clip whose captions use them.
NEGATIVES = {
    "a herd of elephants": r"elephant",
    "giraffe eating leaves": r"giraffe",
    "zebra": r"zebra",
    "bear": r"\bbears?\b",
    "plane taking off": r"plane|aircraft|\bjets?\b|airport",
    "a slice of pizza": r"pizza",
    "surfboard": r"surf",
    "kite": r"\bkites?\b",
    "a lion roaring": r"\blions?\b|roar",
    "fireworks exploding in the night sky": r"firework",
    "guest wifi password": r"wifi|password",
    "javascript promise error": r"javascript|code",
}


class RangeFile(io.RawIOBase):
    """A remote file read by HTTP range requests, so zipfile can list a big archive cheaply."""

    def __init__(self, url):
        self.url, self.pos = url, 0
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD")) as response:
            self.size = int(response.headers["Content-Length"])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = [offset, self.pos + offset, self.size + offset][whence]
        return self.pos

    def readinto(self, buffer):
        data = fetch_range(self.url, self.pos, min(len(buffer), self.size - self.pos))
        buffer[: len(data)] = data
        self.pos += len(data)
        return len(data)


def fetch_range(url, start, length):
    if length <= 0:
        return b""
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def fetch(url, target):
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {url.rsplit('/', 1)[-1]}…")
        partial = target.with_suffix(".partial")
        urllib.request.urlretrieve(url, partial)
        partial.rename(target)
    return target


def videos(names):
    """Fetches the named MSR-VTT clips into the cache, reading only their bytes of the archive."""
    folder = CACHE / "msrvtt/videos"
    folder.mkdir(parents=True, exist_ok=True)
    missing = [n for n in names if not (folder / n).exists()]
    if missing:
        url = MSRVTT + "MSRVTT_Videos.zip"
        print(f"Fetching {len(missing)} MSR-VTT clips…")
        members = {Path(i.filename).name: i for i in zipfile.ZipFile(io.BufferedReader(RangeFile(url), 1 << 20)).infolist()}

        def extract(name):
            info = members[name]
            # Local header: 30 bytes, then name and extra field, whose lengths can differ
            # from the central directory's.
            header = fetch_range(url, info.header_offset, 30)
            name_length, extra_length = struct.unpack("<HH", header[26:30])
            data = fetch_range(url, info.header_offset + 30 + name_length + extra_length, info.compress_size)
            if info.compress_type == zipfile.ZIP_DEFLATED:
                data = zlib.decompress(data, -15)
            partial = folder / (name + ".partial")
            partial.write_bytes(data)
            partial.rename(folder / name)

        with ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(extract, missing))
    return folder


def clotho():
    """Clotho evaluation clips: (original file name, WAV bytes, captions)."""
    import pyarrow.parquet as pq

    table = pq.read_table(fetch(CLOTHO, CACHE / "clotho/test-00000-of-00002.parquet"))
    for row in table.to_pylist():
        yield row["file_name"], row["audio"]["bytes"], [row[f"caption_{i}"].strip() for i in range(1, 6)]


def main():
    root = Path(__file__).resolve().parent.parent / "Evals"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=root / "media")
    parser.add_argument("--photos", type=int, default=300)
    parser.add_argument("--papers", type=int, default=500)
    parser.add_argument("--videos", type=int, default=200)
    parser.add_argument("--audio", type=int, default=200)
    parser.add_argument("--queries", type=int, default=80, help="caption or claim queries per kind")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    for name in ("coco", "scifact"):
        if not (root / name / "queries.json").exists():
            parser.error(f"Evals/{name} is missing: run scripts/coco_bench.py and scripts/beir_bench.py first")
    unwanted = re.compile("|".join(NEGATIVES.values()), re.IGNORECASE)

    corpus = args.out / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    for existing in corpus.iterdir():
        existing.unlink()
    queries = []

    def keep(source, names, wanted, query_names):
        """Links the files every kept query needs, filled up with random others."""
        chosen = set(query_names)
        others = sorted(set(names) - chosen)
        chosen |= set(rng.sample(others, max(0, min(len(others), wanted - len(chosen)))))
        for name in chosen:
            os.link(source / name, corpus / name)
        return chosen

    def restrict(query, present):
        relevant = {p: g for p, g in query["relevant"].items() if p in present}
        ignored = [p for p in query.get("ignored", []) if p in present]
        return {"id": query["id"], "text": query["text"], "relevant": relevant, **({"ignored": ignored} if ignored else {})}

    # Photos: COCO captions and categories.
    coco = json.loads((root / "coco/queries.json").read_text())["queries"]
    captions = rng.sample([q for q in coco if q["id"].startswith("cap-")], args.queries)
    photos = keep(root / "coco/corpus", os.listdir(root / "coco/corpus"), args.photos, [p for q in captions for p in q["relevant"]])
    queries += [restrict(q, photos) for q in captions]
    categories = [restrict(q, photos) for q in coco if q["id"].startswith("cat-")]
    queries += [q for q in categories if len(q["relevant"]) >= 3][:30]

    # Text: SciFact claims.
    scifact = json.loads((root / "scifact/queries.json").read_text())["queries"]
    claims = rng.sample([q for q in scifact if q["relevant"]], args.queries)
    papers = keep(root / "scifact/corpus", os.listdir(root / "scifact/corpus"), args.papers, [p for q in claims for p in q["relevant"]])
    queries += [restrict(q, papers) for q in claims]

    # Videos: MSR-VTT 1k-A, dropping clips any of whose 20 captions mention a negative.
    test = json.loads(fetch(MSRVTT + "msrvtt_test_1k.json", CACHE / "msrvtt/msrvtt_test_1k.json").read_text())
    data = json.loads(fetch(MSRVTT + "raw_data/MSRVTT_data.json", CACHE / "msrvtt/MSRVTT_data.json").read_text())
    flagged = {s["video_id"] for s in data["sentences"] if unwanted.search(s["caption"])}
    pool = sorted((v for v in test if v["video_id"] not in flagged), key=lambda v: v["video"])
    picked = rng.sample(pool, min(args.videos, len(pool)))
    folder = videos([v["video"] for v in picked])
    asked = rng.sample(picked, min(args.queries, len(picked)))
    keep(folder, [v["video"] for v in picked], len(picked), [v["video"] for v in asked])
    queries += [{"id": f"vid-{v['id']}", "text": v["caption"].strip(), "relevant": {v["video"]: 2}} for v in asked]

    # Audio: Clotho evaluation clips under neutral names, one human caption each.
    folder = CACHE / "clotho/clips"
    folder.mkdir(parents=True, exist_ok=True)
    clips = []
    for index, (original, wav, texts) in enumerate(clotho()):
        name = f"rec-{index:04d}.wav"
        if not (folder / name).exists():
            (folder / name).write_bytes(wav)
        if not any(unwanted.search(t) for t in texts):
            clips.append((name, original, texts[0]))
    picked = rng.sample(clips, min(args.audio, len(clips)))
    asked = rng.sample(picked, min(args.queries, len(picked)))
    keep(folder, [c[0] for c in picked], len(picked), [c[0] for c in asked])
    queries += [{"id": f"aud-{Path(name).stem}", "text": text.rstrip("."), "relevant": {name: 2}} for name, _, text in asked]

    for text in NEGATIVES:
        queries.append({"id": f"none-{text.replace(' ', '-')}", "text": text, "relevant": {}})
    for q in queries:
        q["mustPass"] = False
    (args.out / "queries.json").write_text(json.dumps({"queries": queries}, indent=1))
    kinds = {k: sum(q["id"].startswith(k) for q in queries) for k in ("cap-", "cat-", "claim-", "vid-", "aud-", "none-")}
    counts = {ext: sum(n.endswith(ext) for n in os.listdir(corpus)) for ext in (".jpg", ".txt", ".mp4", ".wav")}
    print(f"Linked {counts} into {corpus}; wrote {len(queries)} queries: {kinds}")


if __name__ == "__main__":
    main()
