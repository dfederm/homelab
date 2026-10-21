#!/usr/bin/env python3
"""Download and export a verified Ultralytics YOLO checkpoint for Frigate."""

import argparse
import hashlib
import importlib.metadata
import json
import os
import re
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


ARTIFACTS = ("model.onnx", "labelmap.txt", "metadata.json")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def pinned_requirements():
    requirements = Path(__file__).with_name("requirements-model.txt")
    return dict(
        line.split("==", 1)
        for line in requirements.read_text(encoding="ascii").splitlines()
    )


def verify_existing(directory, checkpoint_sha256, input_size, opset):
    manifest = directory / "SHA256SUMS"
    if not manifest.is_file():
        raise SystemExit(f"ERROR: incomplete model directory: {directory}")
    entries = {}
    for line in manifest.read_text(encoding="ascii").splitlines():
        fields = line.split("  ", 1)
        if len(fields) != 2:
            raise SystemExit("ERROR: invalid model checksum manifest")
        digest, name = fields
        if name not in ARTIFACTS or name in entries:
            raise SystemExit("ERROR: invalid model checksum manifest")
        entries[name] = digest
    if set(entries) != set(ARTIFACTS):
        raise SystemExit("ERROR: incomplete model checksum manifest")
    for name, digest in entries.items():
        path = directory / name
        if not path.is_file() or sha256(path) != digest:
            raise SystemExit(f"ERROR: model verification failed: {path}")
    metadata = json.loads(
        (directory / "metadata.json").read_text(encoding="utf-8")
    )
    if metadata.get("checkpoint_sha256") != checkpoint_sha256:
        raise SystemExit("ERROR: existing model uses a different checkpoint")
    if (
        metadata.get("input_shape") != [1, 3, input_size, input_size]
        or metadata.get("opset") != opset
    ):
        raise SystemExit("ERROR: existing model uses different export settings")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--checkpoint-url", required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--input-size", type=int, default=640)
    parser.add_argument("--opset", type=int, default=13)
    args = parser.parse_args()

    url = urllib.parse.urlsplit(args.checkpoint_url)
    if url.scheme != "https" or not url.netloc:
        parser.error("--checkpoint-url must use HTTPS with a hostname")
    if not re.fullmatch(r"[A-Fa-f0-9]{64}", args.checkpoint_sha256):
        parser.error("--checkpoint-sha256 must be a SHA-256 checksum")
    if args.input_size <= 0 or args.opset <= 0:
        parser.error("--input-size and --opset must be positive integers")
    args.checkpoint_sha256 = args.checkpoint_sha256.lower()
    output = args.output_directory.resolve()

    if output.exists():
        if not output.is_dir():
            raise SystemExit(f"ERROR: model destination must be a directory: {output}")
        if any(output.iterdir()):
            verify_existing(
                output, args.checkpoint_sha256, args.input_size, args.opset
            )
            print(f"Model already verified: {output}")
            return

    versions = {}
    for package, expected in pinned_requirements().items():
        try:
            actual = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError as error:
            raise SystemExit(f"ERROR: model preparation requires {package}") from error
        if actual.split("+", 1)[0] != expected:
            raise SystemExit(
                f"ERROR: {package} must be {expected}, found {actual}; "
                "use requirements-model.txt"
            )
        versions[package] = actual

    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    os.environ["YOLO_AUTOINSTALL"] = "false"
    os.environ["YOLO_OFFLINE"] = "true"
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix=f".prepare-{output.name}-", dir=output.parent
    ) as work:
        work = Path(work)
        (work / "settings").mkdir()
        os.environ["YOLO_CONFIG_DIR"] = str(work / "settings")
        os.environ["MPLCONFIGDIR"] = str(work / "matplotlib")
        os.environ["XDG_CACHE_HOME"] = str(work / "cache")

        import numpy as np
        import onnx
        import onnxruntime as ort
        import torch
        from ultralytics import YOLO

        torch.set_num_threads(2)
        checkpoint = work / "checkpoint.pt"
        with urllib.request.urlopen(args.checkpoint_url, timeout=120) as response:
            with checkpoint.open("wb") as stream:
                while chunk := response.read(1024 * 1024):
                    stream.write(chunk)
        if sha256(checkpoint) != args.checkpoint_sha256:
            raise SystemExit("ERROR: upstream checkpoint checksum mismatch")

        model = YOLO(checkpoint)
        labels = {
            index: name.lower().replace(" ", "_")
            for index, name in sorted(model.names.items())
        }
        if list(labels) != list(range(len(labels))):
            raise SystemExit("ERROR: checkpoint class indices are not contiguous")

        exported = Path(
            model.export(
                format="onnx",
                imgsz=args.input_size,
                opset=args.opset,
                dynamic=False,
                simplify=False,
                nms=None,  # Preserve raw outputs for Frigate's external NMS.
                batch=1,
                device="cpu",
            )
        )
        onnx.checker.check_model(str(exported))
        session = ort.InferenceSession(
            str(exported), providers=["CPUExecutionProvider"]
        )
        input_shape = [1, 3, args.input_size, args.input_size]
        if session.get_inputs()[0].shape != input_shape:
            raise SystemExit("ERROR: unexpected model input shape")
        result = session.run(
            None,
            {session.get_inputs()[0].name: np.zeros(input_shape, dtype=np.float32)},
        )[0]
        if result.ndim != 3 or result.shape[1] != len(labels) + 4:
            raise SystemExit("ERROR: unexpected generic YOLO output shape")
        if not np.isfinite(result).all():
            raise SystemExit("ERROR: model inference produced non-finite output")

        artifacts = work / "artifacts"
        artifacts.mkdir()
        exported.replace(artifacts / "model.onnx")
        (artifacts / "labelmap.txt").write_text(
            "".join(f"{index} {name}\n" for index, name in labels.items()),
            encoding="utf-8",
            newline="\n",
        )
        metadata = {
            "checkpoint_url": args.checkpoint_url,
            "checkpoint_sha256": args.checkpoint_sha256,
            "packages": versions,
            "input_shape": input_shape,
            "output_shape": list(result.shape),
            "opset": args.opset,
            "label_normalization": "lowercase; spaces replaced by underscores",
        }
        (artifacts / "metadata.json").write_text(
            json.dumps(metadata, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        (artifacts / "SHA256SUMS").write_text(
            "".join(f"{sha256(artifacts / name)}  {name}\n" for name in ARTIFACTS),
            encoding="ascii",
            newline="\n",
        )
        artifacts.replace(output)
    print(f"Prepared and verified CPU model: {output}")


if __name__ == "__main__":
    main()
