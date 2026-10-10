"""Generate EmbeddingGemma 2 parity fixtures from the Python MLX-VLM reference.

Usage (in a venv with `mlx-vlm` from the `pc/embeddinggemma-2` branch):
    python scripts/model/make_parity_fixtures.py <checkpoint-dir> <out-dir>

Writes text_fixtures.json, media inputs (PNG/WAV), and media_fixtures.json holding the
reference token ids, preprocessed tensors (flattened) and embeddings. The Swift parity tests
(Tests/GlintEmbeddingTests/EmbeddingGemma2ParityTests.swift) compare against these.
"""

import json
import math
import sys
import wave
from pathlib import Path

import mlx.core as mx
import numpy as np
from PIL import Image, ImageDraw

from mlx_vlm import load

TEXTS = [
    "task: search result | query: Which planet is known as the Red Planet?",
    "title: none | text: Mars, known for its reddish appearance, is often referred to as the Red Planet.",
    "title: none | text: Venus is often called Earth's twin because of its similar size and proximity.",
    "task: search result | query: crowd cheering at night",
    "title: none | text: Café Zürich — naïve résumé 日本語のテキスト 🚀 emoji, code: func scan(matrix: [Float]) -> [Float] { [] }",
]


def make_photo(path: Path, size=(1200, 900)):
    w, h = size
    y, x = np.mgrid[0:h, 0:w]
    sky = np.stack([40 + 120 * y / h, 90 + 100 * y / h, 200 - 60 * y / h], axis=-1)
    image = Image.fromarray(sky.clip(0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(image)
    draw.ellipse([w * 0.6, h * 0.1, w * 0.75, h * 0.3], fill=(250, 220, 120))
    draw.rectangle([0, h * 0.7, w, h], fill=(210, 190, 140))
    draw.polygon([(w * 0.1, h * 0.7), (w * 0.3, h * 0.35), (w * 0.5, h * 0.7)], fill=(70, 90, 60))
    image.save(path)


def make_document(path: Path, size=(640, 900)):
    image = Image.new("RGB", size, (255, 255, 255))
    draw = ImageDraw.Draw(image)
    for row in range(20):
        draw.text((40, 40 + row * 40), f"Invoice line {row}: pricing chart revenue {row * 7}", fill=(0, 0, 0))
    draw.rectangle([380, 600, 600, 860], outline=(0, 0, 200), width=4)
    image.save(path)


def make_audio(path: Path, seconds=3.0, rate=16000):
    t = np.arange(int(seconds * rate)) / rate
    signal = 0.3 * np.sin(2 * math.pi * (220 + 300 * t) * t) + 0.05 * np.random.default_rng(0).standard_normal(t.shape)
    pcm = (signal.clip(-1, 1) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes(pcm.tobytes())
    return signal.astype(np.float32)


def to_list(array):
    return np.array(array.astype(mx.float32) if isinstance(array, mx.array) else array).reshape(-1).tolist()


def main(checkpoint: str, out: str):
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    model, processor = load(checkpoint)

    # Text: tokenizer ids and embeddings with prompts already in the text.
    text_fixtures = []
    for text in TEXTS:
        encoded = processor.tokenizer([text], return_tensors="np")
        embedding = model(
            input_ids=mx.array(encoded["input_ids"]), attention_mask=mx.array(encoded["attention_mask"])
        ).text_embeds[0]
        text_fixtures.append({"text": text, "ids": encoded["input_ids"][0].tolist(), "embedding": to_list(embedding)})
    json.dump({"fixtures": text_fixtures}, open(out_dir / "text_fixtures.json", "w"))

    make_photo(out_dir / "photo.png")
    make_document(out_dir / "document.png")
    samples = make_audio(out_dir / "audio.wav")
    np.save(out_dir / "audio_samples.npy", samples)

    media = []
    cases = [
        ("photo", [{"role": "user", "content": [{"type": "image", "url": str(out_dir / "photo.png")}]}]),
        ("document", [{"role": "user", "content": [{"type": "image", "url": str(out_dir / "document.png")}]}]),
        (
            "photo_with_text",
            [
                {"role": "system", "content": "title: none | text: "},
                {"role": "user", "content": [{"type": "image", "url": str(out_dir / "photo.png")}, {"type": "text", "text": "mountain by the beach"}]},
            ],
        ),
        ("audio", [{"role": "user", "content": [{"type": "audio", "url": str(out_dir / "audio.wav")}]}]),
    ]
    for name, conversation in cases:
        inputs = processor.apply_chat_template([conversation], tokenize=True, return_dict=True, return_tensors="mlx")
        embedding = model(**inputs).text_embeds[0]
        record = {"name": name, "ids": np.array(inputs["input_ids"][0]).tolist(), "embedding": to_list(embedding)}
        for key in ("pixel_values", "image_position_ids", "input_features", "input_features_mask"):
            if key in inputs and inputs[key] is not None:
                value = inputs[key]
                record[key] = {"shape": list(value.shape), "values": to_list(value)}
        media.append(record)
        print(name, "tokens", len(record["ids"]))
    json.dump({"fixtures": media}, open(out_dir / "media_fixtures.json", "w"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
