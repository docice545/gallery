import json

import pytest

from gallery_inpainting.mask import InvalidInput, parse_mask, rasterize_mask


def stroke(points=None, radius=0.05, erase=False):
    return {"points": points or [{"x": 0.5, "y": 0.5}], "radius": radius, "erase": erase}


def test_additive_and_erase_strokes_with_round_caps():
    strokes = parse_mask(json.dumps({"strokes": [stroke(radius=0.2), stroke(radius=0.05, erase=True)]}))
    mask = rasterize_mask(strokes, (100, 100))
    assert mask.getpixel((50, 50)) == 0
    assert mask.getpixel((60, 50)) == 255
    assert mask.getpixel((1, 1)) == 0


def test_line_connects_points_and_clamps_round_cap_to_image():
    strokes = parse_mask(json.dumps({"strokes": [stroke([{"x": 0, "y": 0.5}, {"x": 1, "y": 0.5}])]}))
    mask = rasterize_mask(strokes, (100, 100))
    assert mask.getpixel((0, 50)) == mask.getpixel((99, 50)) == mask.getpixel((50, 50)) == 255


@pytest.mark.parametrize(
    "data",
    [
        [],
        {},
        {"strokes": []},
        {"strokes": [stroke()] * 65},
        {"strokes": [stroke(radius=0)]},
        {"strokes": [stroke(radius=0.251)]},
        {"strokes": [stroke(radius=True)]},
        {"strokes": [stroke(erase=1)]},
        {"strokes": [stroke([{"x": -0.1, "y": 0.5}])]},
        {"strokes": [stroke([{"x": 1.1, "y": 0.5}])]},
        {"strokes": [stroke([{"x": float("nan"), "y": 0.5}])]},
        {"strokes": [stroke([{"x": True, "y": 0.5}])]},
        {"strokes": [stroke([{"x": 0.5, "y": 0.5, "z": 1}])]},
        {"strokes": [stroke([{"x": 0.5, "y": 0.5}] * 1025)]},
        {"strokes": [stroke([{"x": 0.5, "y": 0.5}] * 1024)] * 9},
        {"strokes": [stroke()], "extra": True},
    ],
)
def test_invalid_mask_rejected(data):
    with pytest.raises(InvalidInput):
        parse_mask(json.dumps(data))


@pytest.mark.parametrize("raw", ["{", "x" * (1024 * 1024 + 1), '{"strokes":' + "[" * 1100])
def test_malformed_oversized_or_deeply_nested_json_rejected(raw):
    with pytest.raises(InvalidInput):
        parse_mask(raw)


def test_empty_after_erase_rejected():
    strokes = parse_mask(json.dumps({"strokes": [stroke(), stroke(erase=True)]}))
    with pytest.raises(InvalidInput, match="nonempty"):
        rasterize_mask(strokes, (100, 100))


def test_excessive_coverage_rejected():
    strokes = parse_mask(
        json.dumps({"strokes": [stroke([{"x": 0, "y": y}, {"x": 1, "y": y}], 0.25) for y in (0, 0.5, 1)]})
    )
    with pytest.raises(InvalidInput, match="75%"):
        rasterize_mask(strokes, (100, 100))
