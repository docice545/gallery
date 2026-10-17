import asyncio
import shutil
import threading
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from .config import Settings
from .engine import CancelledJob, InpaintingEngine
from .mask import Stroke


class Busy(Exception):
    pass


class DuplicateJob(Exception):
    pass


class QueueTimeout(Exception):
    pass


@dataclass
class Job:
    id: UUID
    directory: Path
    strokes: tuple[Stroke, ...]
    cancelled: threading.Event
    result: asyncio.Future
    queued_at: float
    started: bool = False


class JobManager:
    """One decoder/inference worker, including the noninterruptible native call."""

    def __init__(self, settings: Settings, engine: InpaintingEngine):
        self.settings = settings
        self.engine = engine
        self.queue: asyncio.Queue[Job] = asyncio.Queue()
        self.jobs: dict[UUID, Job] = {}
        self.worker: asyncio.Task | None = None
        self.stopping = False

    async def start(self) -> None:
        self.settings.work_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        # A private work directory belongs to exactly this single worker process.
        for directory in self.settings.work_dir.glob("job-*"):
            if directory.is_dir() and not directory.is_symlink():
                await asyncio.to_thread(shutil.rmtree, directory, True)
        self.worker = asyncio.create_task(self._work())

    def submit(self, id: UUID, directory: Path, strokes: tuple[Stroke, ...]) -> Job:
        if id in self.jobs:
            raise DuplicateJob()
        if self.stopping or len(self.jobs) >= self.settings.max_waiting + 1:
            raise Busy()
        loop = asyncio.get_running_loop()
        job = Job(id, directory, strokes, threading.Event(), loop.create_future(), loop.time())
        self.jobs[id] = job
        self.queue.put_nowait(job)
        return job

    def cancel(self, id: UUID) -> bool:
        job = self.jobs.get(id)
        if job is None:
            return False
        job.cancelled.set()
        # Resolving lets callers stop waiting; the worker still holds its slot and files.
        if not job.result.done():
            job.result.set_result(CancelledJob())
        return True

    async def _work(self) -> None:
        while not self.stopping:
            try:
                job = await asyncio.wait_for(self.queue.get(), self.settings.idle_unload_seconds)
            except TimeoutError:
                await asyncio.to_thread(self.engine.unload)
                continue
            try:
                if job.cancelled.is_set():
                    raise CancelledJob()
                if asyncio.get_running_loop().time() - job.queued_at > self.settings.queue_timeout:
                    raise QueueTimeout()
                job.started = True
                path = await asyncio.to_thread(
                    self.engine.process,
                    job.directory / "input",
                    job.directory / "result.jpg",
                    job.strokes,
                    job.cancelled,
                )
                if job.cancelled.is_set():
                    raise CancelledJob()
                if not job.result.done():
                    job.result.set_result(path)
            except Exception as error:
                # Return error values, rather than unobserved Future exceptions on disconnect.
                if not job.result.done():
                    job.result.set_result(error)
                await asyncio.to_thread(shutil.rmtree, job.directory, True)
            finally:
                self.jobs.pop(job.id, None)
                self.queue.task_done()

    async def stop(self) -> None:
        self.stopping = True
        for job in tuple(self.jobs.values()):
            self.cancel(job.id)
        # Cancellation cannot stop a Torch native call safely: wait for it to finish.
        if self.worker is not None:
            if self.jobs:
                await self.worker
            else:
                self.worker.cancel()
                try:
                    await self.worker
                except asyncio.CancelledError:
                    pass
        for job in tuple(self.jobs.values()):
            await asyncio.to_thread(shutil.rmtree, job.directory, True)
        self.jobs.clear()
        await asyncio.to_thread(self.engine.unload)
