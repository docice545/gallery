import json
import math
from dataclasses import dataclass

from PIL import Image, ImageDraw


class InvalidInput(ValueError):
    pass


@dataclass(frozen=True)
class Stroke:
    points: tuple[tuple[float, float], ...]
    radius: float
    erase: bool


def _number(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidInput("Mask coordinates and radii must be finite numbers")
    try:
        result = float(value)
    except (OverflowError, ValueError) as error:
        raise InvalidInput("Mask coordinates and radii must be finite numbers") from error
    if not math.isfinite(result):
        raise InvalidInput("Mask coordinates and radii must be finite numbers")
    return result


def parse_mask(raw: str) -> tuple[Stroke, ...]:
    if len(raw.encode("utf-8")) > 1024 * 1024:
        raise InvalidInput("Mask instructions exceed 1MiB")
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError) as error:
        raise InvalidInput("Invalid mask JSON") from error
    if not isinstance(data, dict) or set(data) != {"strokes"}:
        raise InvalidInput("Mask must contain only strokes")
    strokes = data["strokes"]
    if not isinstance(strokes, list) or not 1 <= len(strokes) <= 64:
        raise InvalidInput("Mask requires from 1 to 64 strokes")
    result = []
    total_points = 0
    for stroke in strokes:
        if not isinstance(stroke, dict) or set(stroke) != {"points", "radius", "erase"}:
            raise InvalidInput("Each stroke requires points, radius and erase")
        radius = _number(stroke["radius"])
        if not 0.001 <= radius <= 0.25 or not isinstance(stroke["erase"], bool):
            raise InvalidInput("Radius must be from 0.001 to 0.25 and erase must be boolean")
        points = stroke["points"]
        if not isinstance(points, list) or not 1 <= len(points) <= 1024:
            raise InvalidInput("A stroke requires from 1 to 1024 points")
        total_points += len(points)
        if total_points > 8192:
            raise InvalidInput("Mask exceeds 8192 points")
        coordinates = []
        for point in points:
            if not isinstance(point, dict) or set(point) != {"x", "y"}:
                raise InvalidInput("Each point requires x and y")
            x, y = _number(point["x"]), _number(point["y"])
            if not 0 <= x <= 1 or not 0 <= y <= 1:
                raise InvalidInput("Mask coordinates must be from 0 to 1")
            coordinates.append((x, y))
        result.append(Stroke(tuple(coordinates), radius, stroke["erase"]))
    return tuple(result)


def rasterize_mask(strokes: tuple[Stroke, ...], size: tuple[int, int]) -> Image.Image:
    width, height = size
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    for stroke in strokes:
        points = [(x * (width - 1), y * (height - 1)) for x, y in stroke.points]
        radius = max(0.5, stroke.radius * min(width, height))
        fill = 0 if stroke.erase else 255
        if len(points) > 1:
            draw.line(points, fill=fill, width=max(1, round(radius * 2)), joint="curve")
        # Explicit discs ensure consistent round caps, including single-point taps.
        for x, y in points:
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)
    selected = sum(mask.histogram()[1:])
    if selected == 0 or selected > width * height * 0.75:
        mask.close()
        raise InvalidInput("Select a nonempty area covering at most 75% of the image")
    return mask
