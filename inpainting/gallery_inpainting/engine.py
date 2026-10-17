import gc
import hashlib
import threading
from pathlib import Path
from typing import Protocol

import numpy as np
from PIL import Image, ImageChops, ImageFilter

from .config import Settings
from .mask import InvalidInput, Stroke, rasterize_mask


class CancelledJob(Exception):
    pass


class ModelUnavailable(Exception):
    pass


class Predictor(Protocol):
    def predict(self, image: np.ndarray, mask: np.ndarray) -> np.ndarray: ...

    def unload(self) -> None: ...

    def available(self) -> bool: ...


class TorchScriptPredictor:
    """IOPaint-compatible Big-LaMa interface, with no downloading or network code."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.model = None
        self._verified_stat: tuple[int, int, int] | None = None
        self._verification_lock = threading.Lock()

    def available(self) -> bool:
        if not self.settings.model_sha256:
            return False
        with self._verification_lock:
            try:
                stat = self.settings.model_path.stat()
                fingerprint = (stat.st_ino, stat.st_mtime_ns, stat.st_size)
                if self._verified_stat != fingerprint:
                    with self.settings.model_path.open("rb") as model_file:
                        digest = hashlib.file_digest(model_file, "sha256").hexdigest()
                    if digest != self.settings.model_sha256:
                        return False
                    self._verified_stat = fingerprint
                return True
            except OSError:
                return False

    def _load(self):
        if self.model is not None:
            return self.model
        if not self.available():
            raise ModelUnavailable("A local model and verified SHA-256 must be configured")
        # Torch is imported only when inference is requested, so idle startup is light.
        import torch

        torch.set_num_threads(self.settings.cpu_threads)
        try:
            model = torch.jit.load(str(self.settings.model_path), map_location="cpu")
            model.eval()
        except (RuntimeError, OSError, ValueError) as error:
            raise ModelUnavailable("The local TorchScript model could not be loaded") from error
        self.model = model
        return model

    def predict(self, image: np.ndarray, mask: np.ndarray) -> np.ndarray:
        import torch

        model = self._load()
        image_tensor = torch.from_numpy(np.ascontiguousarray(image.transpose(2, 0, 1))).float().div_(255).unsqueeze(0)
        mask_tensor = torch.from_numpy(np.ascontiguousarray(mask[None])).float().gt_(0).unsqueeze(0)
        with torch.inference_mode():
            output = model(image_tensor, mask_tensor)
        if (
            not isinstance(output, torch.Tensor)
            or output.shape != image_tensor.shape
            or not torch.isfinite(output).all()
        ):
            raise ModelUnavailable("The inpainting model returned an invalid image")
        return output[0].permute(1, 2, 0).clamp(0, 1).mul(255).byte().cpu().numpy()

    def unload(self) -> None:
        self.model = None
        gc.collect()


class InpaintingEngine:
    def __init__(self, settings: Settings, predictor: Predictor | None = None):
        self.settings = settings
        self.predictor = predictor or TorchScriptPredictor(settings)

    def available(self) -> bool:
        return self.predictor.available()

    def unload(self) -> None:
        self.predictor.unload()

    def process(
        self, image_path: Path, output_path: Path, strokes: tuple[Stroke, ...], cancelled: threading.Event
    ) -> Path:
        if cancelled.is_set():
            raise CancelledJob()
        try:
            with Image.open(image_path) as source:
                if source.format not in {"JPEG", "PNG"} or getattr(source, "n_frames", 1) != 1:
                    raise InvalidInput("Only a single upright JPEG or PNG image is accepted")
                width, height = source.size
                if width < 8 or height < 8 or width * height > self.settings.max_pixels:
                    raise InvalidInput("Image must be at least 8x8 and within the configured pixel limit")
                if source.getexif().get(274, 1) != 1:
                    raise InvalidInput("The server must normalize EXIF orientation before inference")
                source.load()
                original = source.convert("RGB")
        except (Image.DecompressionBombError, OSError, SyntaxError, ValueError) as error:
            if isinstance(error, InvalidInput):
                raise
            raise InvalidInput("The source image cannot be decoded safely") from error

        mask = None
        crop = crop_mask = resized = resized_mask = replacement = alpha = feather = float_mask = None
        try:
            mask = rasterize_mask(strokes, original.size)
            bbox = mask.getbbox()
            assert bbox is not None
            max_radius = max(stroke.radius for stroke in strokes) * min(original.size)
            context = max(64, round(max_radius * 2), round(max(bbox[2] - bbox[0], bbox[3] - bbox[1]) * 0.2))
            roi = (
                max(0, bbox[0] - context),
                max(0, bbox[1] - context),
                min(width, bbox[2] + context),
                min(height, bbox[3] + context),
            )
            crop = original.crop(roi)
            crop_mask = mask.crop(roi)
            ratio = min(1, self.settings.max_working_size / max(crop.size))
            working_size = (max(1, round(crop.width * ratio)), max(1, round(crop.height * ratio)))
            resized = crop.resize(working_size, Image.Resampling.LANCZOS)
            # Floating BOX preserves occupancy even when tiny marks average below 1/255.
            float_mask = crop_mask.convert("F")
            resized_mask = float_mask.resize(working_size, Image.Resampling.BOX)
            float_mask.close()
            float_mask = None
            rgb = np.array(resized)
            working_mask = (np.array(resized_mask) > 0).astype(np.uint8) * 255
            # Three encoder strides need >=16 pixels for the internal reflection padding.
            pad_h = max(16, working_size[1] + (-working_size[1]) % 8) - working_size[1]
            pad_w = max(16, working_size[0] + (-working_size[0]) % 8) - working_size[0]
            rgb = np.pad(rgb, ((0, pad_h), (0, pad_w), (0, 0)), mode="reflect")
            working_mask = np.pad(working_mask, ((0, pad_h), (0, pad_w)), mode="reflect")
            if cancelled.is_set():
                raise CancelledJob()
            predicted = self.predictor.predict(rgb, working_mask)
            if cancelled.is_set():
                raise CancelledJob()
            if predicted.shape != rgb.shape or predicted.dtype != np.uint8:
                raise ModelUnavailable("The inpainting predictor returned an invalid image")
            replacement = Image.fromarray(predicted[: working_size[1], : working_size[0]]).resize(
                crop.size, Image.Resampling.LANCZOS
            )
            # Feather inward, without changing any pixel outside the selected area.
            if min(bbox[2] - bbox[0], bbox[3] - bbox[1]) <= 4:
                alpha = crop_mask.copy()
            else:
                feather = crop_mask.filter(ImageFilter.GaussianBlur(radius=min(1.5, max_radius / 6)))
                alpha = ImageChops.multiply(crop_mask, feather)
            original.paste(replacement, roi[:2], alpha)
            original.save(output_path, format="JPEG", quality=95, subsampling=0)
            if cancelled.is_set():
                output_path.unlink(missing_ok=True)
                raise CancelledJob()
            if output_path.stat().st_size > self.settings.max_image_bytes:
                output_path.unlink(missing_ok=True)
                raise InvalidInput("The result exceeds the configured image size limit")
            return output_path
        finally:
            original.close()
            for resource in (mask, crop, crop_mask, resized, resized_mask, replacement, alpha, feather, float_mask):
                if resource is not None:
                    resource.close()
