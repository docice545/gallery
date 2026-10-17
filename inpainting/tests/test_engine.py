import hashlib
import json
import os
import threading
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from gallery_inpainting.config import Settings
from gallery_inpainting.engine import CancelledJob, InpaintingEngine, ModelUnavailable, TorchScriptPredictor
from gallery_inpainting.mask import InvalidInput, parse_mask


class SolidPredictor:
    def __init__(self):
        self.calls = []
        self.unloads = 0

    def available(self):
        return True

    def predict(self, image, mask):
        self.calls.append((image.shape, mask.copy()))
        result = np.zeros_like(image)
        result[:, :, 0] = 255
        return result

    def unload(self):
        self.unloads += 1


def make_settings(tmp_path, **kwargs):
    return Settings(token="test-token-" + "x" * 32, work_dir=tmp_path / "work", **kwargs)


def make_strokes(radius=0.08, points=None):
    return parse_mask(
        json.dumps({"strokes": [{"points": points or [{"x": 0.5, "y": 0.5}], "radius": radius, "erase": False}]})
    )


def test_full_dimensions_original_untouched_and_unmasked_area_preserved(tmp_path):
    source = tmp_path / "source.png"
    original = Image.new("RGB", (1600, 1000), (100, 100, 100))
    original.save(source)
    before = source.read_bytes()
    predictor = SolidPredictor()
    output = tmp_path / "out.jpg"
    InpaintingEngine(make_settings(tmp_path), predictor).process(source, output, make_strokes(), threading.Event())
    with Image.open(output) as edited:
        assert edited.size == original.size
        assert edited.getpixel((10, 10)) == (100, 100, 100)
        assert edited.getpixel((800, 500))[0] > 240
        assert not edited.getexif()
    assert source.read_bytes() == before
    shape, mask = predictor.calls[0]
    assert max(shape[:2]) <= 512
    assert shape[0] % 8 == shape[1] % 8 == 0
    assert mask.any()


def test_tiny_panorama_taps_are_not_lost_during_mask_resizing(tmp_path):
    source = tmp_path / "panorama.png"
    Image.new("RGB", (20_000, 800), (100, 100, 100)).save(source)
    predictor = SolidPredictor()
    strokes = make_strokes(0.001, [{"x": 0.01, "y": 0.5}, {"x": 0.99, "y": 0.5}])
    # Separate taps, not a connecting line across the panorama.
    strokes = tuple(type(strokes[0])((point,), 0.001, False) for point in strokes[0].points)
    InpaintingEngine(make_settings(tmp_path), predictor).process(
        source, tmp_path / "out.jpg", strokes, threading.Event()
    )
    assert predictor.calls[0][1].any()
    assert min(predictor.calls[0][0][:2]) >= 16


def test_tiny_tap_is_replaced_fully_without_excessive_feather(tmp_path):
    source = tmp_path / "source.png"
    Image.new("RGB", (100, 100), (100, 100, 100)).save(source)
    output = tmp_path / "out.jpg"
    InpaintingEngine(make_settings(tmp_path), SolidPredictor()).process(
        source, output, make_strokes(0.001), threading.Event()
    )
    with Image.open(output) as edited:
        assert edited.getpixel((49, 49))[0] > 220


def test_eight_pixel_photo_is_padded_to_model_minimum(tmp_path):
    source = tmp_path / "source.png"
    Image.new("RGB", (8, 8)).save(source)
    predictor = SolidPredictor()
    output = tmp_path / "out.jpg"
    InpaintingEngine(make_settings(tmp_path), predictor).process(source, output, make_strokes(), threading.Event())
    assert predictor.calls[0][0] == (16, 16, 3)
    with Image.open(output) as edited:
        assert edited.size == (8, 8)


@pytest.mark.parametrize("size", [(7, 20), (20, 7), (6001, 6000)])
def test_unsafe_dimensions_rejected_before_model(tmp_path, size):
    source = tmp_path / "source.png"
    Image.new("RGB", size).save(source)
    predictor = SolidPredictor()
    with pytest.raises(InvalidInput):
        InpaintingEngine(make_settings(tmp_path), predictor).process(
            source, tmp_path / "out.jpg", make_strokes(), threading.Event()
        )
    assert not predictor.calls


def test_unrotated_exif_orientation_rejected(tmp_path):
    source = tmp_path / "source.jpg"
    exif = Image.Exif()
    exif[274] = 6
    Image.new("RGB", (100, 80)).save(source, exif=exif)
    with pytest.raises(InvalidInput, match="orientation"):
        InpaintingEngine(make_settings(tmp_path), SolidPredictor()).process(
            source, tmp_path / "out.jpg", make_strokes(), threading.Event()
        )


@pytest.mark.parametrize("kind", ["corrupt", "gif"])
def test_unsupported_or_corrupt_input_rejected(tmp_path, kind):
    source = tmp_path / "source"
    if kind == "corrupt":
        source.write_bytes(b"not an image")
    else:
        Image.new("RGB", (100, 100)).save(source, format="GIF")
    with pytest.raises(InvalidInput):
        InpaintingEngine(make_settings(tmp_path), SolidPredictor()).process(
            source, tmp_path / "out.jpg", make_strokes(), threading.Event()
        )


def test_cancellation_before_inference(tmp_path):
    event = threading.Event()
    event.set()
    predictor = SolidPredictor()
    with pytest.raises(CancelledJob):
        InpaintingEngine(make_settings(tmp_path), predictor).process(
            tmp_path / "missing", tmp_path / "out.jpg", make_strokes(), event
        )
    assert not predictor.calls


def test_cancellation_during_native_inference_discards_result(tmp_path):
    event = threading.Event()

    class CancellingPredictor(SolidPredictor):
        def predict(self, image, mask):
            result = super().predict(image, mask)
            event.set()
            return result

    source = tmp_path / "source.png"
    Image.new("RGB", (100, 100)).save(source)
    output = tmp_path / "out.jpg"
    with pytest.raises(CancelledJob):
        InpaintingEngine(make_settings(tmp_path), CancellingPredictor()).process(source, output, make_strokes(), event)
    assert not output.exists()


def test_invalid_predictor_output_rejected(tmp_path):
    class InvalidPredictor(SolidPredictor):
        def predict(self, image, mask):
            return np.zeros((1, 1, 3), dtype=np.uint8)

    source = tmp_path / "source.png"
    Image.new("RGB", (100, 100)).save(source)
    with pytest.raises(ModelUnavailable):
        InpaintingEngine(make_settings(tmp_path), InvalidPredictor()).process(
            source, tmp_path / "out.jpg", make_strokes(), threading.Event()
        )


def test_model_checksum_is_verified_and_invalidated_on_file_change(tmp_path):
    path = tmp_path / "model.pt"
    path.write_bytes(b"fake model")
    predictor = TorchScriptPredictor(
        make_settings(tmp_path, model_path=path, model_sha256=hashlib.sha256(b"fake model").hexdigest())
    )
    assert predictor.available()
    path.write_bytes(b"modified model")
    assert not predictor.available()


def test_model_missing_or_wrong_checksum_never_loads(tmp_path):
    path = tmp_path / "model.pt"
    path.write_bytes(b"wrong artifact")
    predictor = TorchScriptPredictor(make_settings(tmp_path, model_path=path))
    assert not predictor.available()
    with pytest.raises(ModelUnavailable):
        predictor._load()


@pytest.mark.real_model
def test_verified_local_big_lama_end_to_end(tmp_path):
    path = os.environ.get("INPAINTING_TEST_MODEL")
    if not path:
        pytest.skip("Explicit verified local model not provided; no model is downloaded by tests")
    settings = make_settings(tmp_path, model_path=Path(path))
    engine = InpaintingEngine(settings)
    assert engine.available()
    source = tmp_path / "source.png"
    image = Image.new("RGB", (320, 240), (60, 100, 150))
    image.paste((255, 0, 0), (145, 105, 175, 135))
    image.save(source)
    output = tmp_path / "result.jpg"
    engine.process(source, output, make_strokes(0.12), threading.Event())
    with Image.open(output) as edited:
        assert edited.size == (320, 240)
        assert edited.getpixel((160, 120))[0] < 200
        assert max(abs(a - b) for a, b in zip(edited.getpixel((5, 5)), (60, 100, 150))) <= 2
    # Minimum shape needed by this exact artifact, not merely mocked player shapes.
    prediction = engine.predictor.predict(np.zeros((16, 512, 3), np.uint8), np.zeros((16, 512), np.uint8))
    assert prediction.shape == (16, 512, 3)
    engine.unload()
