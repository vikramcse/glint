"""Convert OpenCV Zoo's SFace face recognizer to the Core ML model bundled with Glint.

Usage (in a Python 3.12 venv with `torch onnx onnx2torch onnxruntime coremltools numpy`):
    curl -L -o sface.onnx \
        https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
    python scripts/model/convert_sface.py sface.onnx Sources/GlintExtractors/Resources

SFace (MobileFaceNet trained with the SFace loss, 99.4% on LFW) is Apache-2.0. It takes a
112x112 RGB face aligned to the ArcFace five-point template, with pixel values 0...255 (the
network normalizes them itself), and returns a 128-dimensional identity vector.

Writes SFace.mlpackage next to this script's output and compiles it to SFace.mlmodelc with
`xcrun coremlc`, after checking the Core ML output against onnxruntime.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime
import torch
from onnx2torch import convert


def main() -> None:
    onnx_path, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    model = convert(str(onnx_path)).eval()
    example = torch.rand(1, 3, 112, 112) * 255
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="identity")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "SFace face recognizer (OpenCV Zoo, Apache-2.0): aligned 112x112 RGB face to a 128-d identity vector."
    mlmodel.license = "Apache-2.0"

    package = out_dir / "SFace.mlpackage"
    shutil.rmtree(package, ignore_errors=True)
    mlmodel.save(str(package))
    check_parity(onnx_path, package)

    compiled = out_dir / "SFace.mlmodelc"
    shutil.rmtree(compiled, ignore_errors=True)
    subprocess.run(["xcrun", "coremlc", "compile", str(package), str(out_dir)], check=True)
    shutil.rmtree(package)
    print(f"Wrote {compiled}")


def check_parity(onnx_path: Path, package: Path) -> None:
    """Fails unless Core ML and onnxruntime agree on random faces (cosine > 0.999)."""
    from PIL import Image

    session = onnxruntime.InferenceSession(str(onnx_path))
    mlmodel = ct.models.MLModel(str(package))
    rng = np.random.default_rng(0)
    for _ in range(4):
        pixels = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)
        reference = session.run(None, {"data": pixels.transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
        converted = mlmodel.predict({"face": Image.fromarray(pixels)})["identity"].reshape(-1)
        cosine = float(np.dot(reference, converted) / (np.linalg.norm(reference) * np.linalg.norm(converted)))
        print(f"parity cosine {cosine:.5f}")
        if cosine < 0.999:
            sys.exit("Core ML output does not match onnxruntime")


if __name__ == "__main__":
    main()
