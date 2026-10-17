import os
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    token: str
    model_path: Path = Path("/models/big-lama.pt")
    model_sha256: str = "344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9"
    work_dir: Path = Path("/tmp/gallery-inpainting")
    max_pixels: int = 36_000_000
    max_image_bytes: int = 64 * 1024 * 1024
    max_working_size: int = 512
    cpu_threads: int = 2
    max_waiting: int = 3
    queue_timeout: float = 120.0
    idle_unload_seconds: float = 300.0

    def __post_init__(self) -> None:
        if len(self.token) < 32:
            raise ValueError("GALLERY_INPAINTING_TOKEN must contain at least 32 characters")
        if self.model_sha256 and not re.fullmatch(r"[0-9a-f]{64}", self.model_sha256):
            raise ValueError("INPAINTING_MODEL_SHA256 must be a lowercase SHA-256 digest")
        if not 256 <= self.max_working_size <= 1024 or self.max_working_size % 8:
            raise ValueError("INPAINTING_WORKING_SIZE must be a multiple of 8 from 256 to 1024")
        if not 1 <= self.cpu_threads <= 4:
            raise ValueError("INPAINTING_CPU_THREADS must be from 1 to 4")
        if not 0 <= self.max_waiting <= 3:
            raise ValueError("INPAINTING_MAX_WAITING must be from 0 to 3")
        if not 1 <= self.max_pixels <= 36_000_000 or not 1 <= self.max_image_bytes <= 64 * 1024 * 1024:
            raise ValueError("Image limits may be reduced but cannot exceed 36MP / 64MiB")
        if not 1 <= self.queue_timeout <= 600 or not 1 <= self.idle_unload_seconds <= 3600:
            raise ValueError("Queue timeout and idle-unload settings are outside safe bounds")

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            token=os.environ.get("GALLERY_INPAINTING_TOKEN", ""),
            model_path=Path(os.environ.get("INPAINTING_MODEL_PATH", "/models/big-lama.pt")),
            model_sha256=os.environ.get("INPAINTING_MODEL_SHA256", cls.model_sha256),
            work_dir=Path(os.environ.get("INPAINTING_WORK_DIR", "/tmp/gallery-inpainting")),
            max_pixels=int(os.environ.get("INPAINTING_MAX_PIXELS", "36000000")),
            max_image_bytes=int(os.environ.get("INPAINTING_MAX_IMAGE_BYTES", str(64 * 1024 * 1024))),
            max_working_size=int(os.environ.get("INPAINTING_WORKING_SIZE", "512")),
            cpu_threads=int(os.environ.get("INPAINTING_CPU_THREADS", "2")),
            max_waiting=int(os.environ.get("INPAINTING_MAX_WAITING", "3")),
            queue_timeout=float(os.environ.get("INPAINTING_QUEUE_TIMEOUT", "120")),
            idle_unload_seconds=float(os.environ.get("INPAINTING_IDLE_UNLOAD_SECONDS", "300")),
        )
