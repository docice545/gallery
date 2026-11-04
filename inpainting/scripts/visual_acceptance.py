#!/usr/bin/env python3
"""Reproducible synthetic visual QA with the real, checksum-verified Big-LaMa.

No photographs, network access or mock predictor. Outputs are review artifacts,
not an assertion of photorealistic quality on users' images.
Run from inpainting: python scripts/visual_acceptance.py --model /path/big-lama.pt --output /new/evidence
"""

import argparse
import hashlib
import json
import sys
import threading
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gallery_inpainting.config import Settings
from gallery_inpainting.engine import InpaintingEngine
from gallery_inpainting.mask import parse_mask, rasterize_mask


def scene(kind, size=(480, 320)):
    width, height = size
    rng = np.random.default_rng(38)
    yy, xx = np.mgrid[:height, :width]
    if kind == "brick-object":
        base = np.full((height, width, 3), [160, 103, 75], dtype=np.float32)
        mortar = (yy % 35 < 3) | ((xx + (yy // 35 % 2) * 40) % 80 < 3)
        base[mortar] = [211, 197, 180]
    elif kind == "water-person":
        wave = np.sin(xx / 19 + yy / 6) * 9 + np.sin(yy / 3) * 7
        base = np.stack([65 + wave, 135 + wave, 170 + wave], axis=2)
    elif kind == "grass-dog":
        base = np.full((height, width, 3), [83, 126, 62], dtype=np.float32)
        base += rng.normal(0, 13, (height, width, 1))
    else:
        light = xx / width * 30 + yy / height * 20
        base = np.stack([158 + light, 153 + light, 145 + light], axis=2)
        base += rng.normal(0, 3, (height, width, 1))
    clean = Image.fromarray(np.uint8(np.clip(base, 0, 255)))
    source = clean.copy()
    draw = ImageDraw.Draw(source)
    # A single closed lasso encloses the object AND its contact shadow.
    draw.ellipse((190, 218, 302, 242), fill=(65, 65, 58))
    if kind == "water-person":
        draw.ellipse((226, 110, 249, 135), fill=(212, 168, 129))
        draw.rounded_rectangle((218, 133, 258, 194), radius=9, fill=(218, 60, 55))
        draw.line((228, 187, 219, 229), fill=(48, 49, 62), width=12)
        draw.line((248, 187, 263, 229), fill=(48, 49, 62), width=12)
    elif kind == "grass-dog":
        draw.ellipse((195, 162, 264, 211), fill=(166, 102, 56))
        draw.ellipse((251, 145, 289, 183), fill=(148, 83, 48))
        draw.polygon([(253, 157), (250, 134), (268, 147)], fill=(82, 51, 35))
        for x in (205, 243):
            draw.line((x, 198, x - 4, 229), fill=(148, 83, 48), width=10)
        draw.line((200, 178, 183, 151), fill=(148, 83, 48), width=8)
    else:
        draw.rounded_rectangle((218, 132, 264, 226), radius=8, fill=(214, 60, 49))
        draw.rectangle((228, 120, 254, 135), fill=(51, 61, 69))
    return clean, source


def run(model, output):
    output.mkdir(parents=True, exist_ok=False)
    settings = Settings(token="visual-qa-local-" + "x" * 32, work_dir=output / "work", model_path=model)
    engine = InpaintingEngine(settings)
    if not engine.available():
        raise RuntimeError("Verified model unavailable; visual QA was not run")
    cases = []
    rows = []
    for kind in ("brick-object", "water-person", "grass-dog", "texture-object-shadow"):
        clean, source = scene(kind)
        original = output / f"{kind}-before.png"
        source.save(original)
        original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
        points = [(175, 104), (298, 104), (312, 249), (177, 249), (175, 104)]
        strokes = parse_mask(json.dumps({"strokes": [{
            "points": [{"x": x / 480, "y": y / 320} for x, y in points], "radius": .012, "erase": False,
        }]}))
        mask = rasterize_mask(strokes, source.size)
        mask.save(output / f"{kind}-mask.png")
        target = output / f"{kind}-after.jpg"
        started = time.monotonic()
        engine.process(original, target, strokes, threading.Event())
        seconds = time.monotonic() - started
        edited = Image.open(target).convert("RGB")
        assert edited.size == source.size
        assert hashlib.sha256(original.read_bytes()).hexdigest() == original_hash
        before = np.asarray(source, dtype=float)
        after = np.asarray(edited, dtype=float)
        truth = np.asarray(clean, dtype=float)
        interior = np.asarray(mask) > 0
        outside = np.zeros(interior.shape, dtype=bool)
        outside[:80, :] = True  # Far from the feather/JPEG boundary.
        error_before = float(np.abs(before[interior] - truth[interior]).mean())
        error_after = float(np.abs(after[interior] - truth[interior]).mean())
        cases.append({
            "case": kind, "inference_seconds": round(seconds, 3),
            "masked_mae_before": round(error_before, 3), "masked_mae_after": round(error_after, 3),
            "unmasked_mae": round(float(np.abs(before[outside] - after[outside]).mean()), 3),
            "original_sha256": original_hash, "result_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "original_preserved": True, "dimensions_preserved": True,
            "visual_review": "PENDING", "real_photo_quality": "DEVICE_REQUIRED",
        })
        overlay = source.copy()
        tint = Image.new("RGB", source.size, (165, 75, 240))
        overlay.paste(Image.blend(source, tint, .45), mask=mask)
        row = Image.new("RGB", (480 * 3, 350), "white")
        for index, (label, frame) in enumerate((("BEFORE", source), ("CLOSED CONTOUR", overlay), ("REAL BIG-LAMA", edited))):
            row.paste(frame, (index * 480, 30))
            ImageDraw.Draw(row).text((index * 480 + 12, 8), f"{kind} / {label}", fill="black")
        rows.append(row)
    engine.unload()
    sheet = Image.new("RGB", (1440, 350 * len(rows)), "white")
    for index, row in enumerate(rows):
        sheet.paste(row, (0, index * 350))
    sheet.save(output / "contact-sheet.png")
    report = {"model_sha256": settings.model_sha256, "synthetic_only": True, "cases": cases}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.model, args.output)
