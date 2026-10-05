import asyncio
import secrets
import shutil
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated
from uuid import UUID

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import Settings
from .engine import CancelledJob, InpaintingEngine, ModelUnavailable
from .jobs import Busy, DuplicateJob, JobManager, QueueTimeout
from .mask import InvalidInput, parse_mask


class RequestSizeLimit:
    def __init__(self, app, limit: int):
        self.app = app
        self.limit = limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        try:
            declared = int(headers.get(b"content-length", b"0"))
        except ValueError:
            declared = self.limit + 1
        if declared > self.limit:
            return await JSONResponse({"detail": "Request too large"}, 413)(scope, receive, send)
        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            received += len(message.get("body", b""))
            if received > self.limit:
                raise StarletteHTTPException(413, "Request too large")
            return message

        await self.app(scope, limited_receive, send)


class PrivateAdmission:
    """Authenticate and bound uploads before FastAPI parses multipart bodies."""

    def __init__(self, app, settings: Settings, manager: JobManager):
        self.app = app
        self.settings = settings
        self.manager = manager
        self.posts = 0

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        authorization = dict(scope.get("headers", [])).get(b"authorization", b"").decode("latin-1")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not secrets.compare_digest(
            token.encode("utf-8"), self.settings.token.encode("utf-8")
        ):
            return await JSONResponse(
                {"detail": "Authentication required"}, 401, headers={"WWW-Authenticate": "Bearer"}
            )(scope, receive, send)
        admitted = scope["method"] == "POST" and scope["path"] == "/inpaint"
        if admitted:
            held_cancelled = sum(job.result.done() for job in self.manager.jobs.values())
            if self.posts + held_cancelled >= self.settings.max_waiting + 1:
                return await JSONResponse({"detail": "Inpainting queue is full"}, 429, headers={"Retry-After": "5"})(
                    scope, receive, send
                )
            self.posts += 1
        try:
            await self.app(scope, receive, send)
        finally:
            if admitted:
                self.posts -= 1


class TemporaryFileResponse(FileResponse):
    def __init__(self, path: Path, directory: Path):
        super().__init__(path, media_type="image/jpeg", filename="erased.jpg", headers={"Cache-Control": "no-store"})
        self.directory = directory

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            await asyncio.to_thread(shutil.rmtree, self.directory, True)


def create_app(settings: Settings | None = None, engine: InpaintingEngine | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = engine or InpaintingEngine(settings)
    manager = JobManager(settings, engine)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await manager.start()
        try:
            yield
        finally:
            await manager.stop()

    # This is a private worker, not a public Gallery API. Keep docs disabled.
    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(RequestSizeLimit, limit=settings.max_image_bytes + 2 * 1024 * 1024)
    app.add_middleware(PrivateAdmission, settings=settings, manager=manager)
    app.state.manager = manager
    app.state.engine = engine
    bearer = HTTPBearer(auto_error=False)

    def authorized(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]):
        if credentials is None or not secrets.compare_digest(
            credentials.credentials.encode("utf-8"), settings.token.encode("utf-8")
        ):
            raise HTTPException(401, "Authentication required", headers={"WWW-Authenticate": "Bearer"})

    @app.get("/health", dependencies=[Depends(authorized)])
    async def health():
        return {
            "ready": await asyncio.to_thread(engine.available),
            "engine": "big-lama",
            "device": "cpu",
            "maxWorkingSize": settings.max_working_size,
            "maxPixels": settings.max_pixels,
            "active": sum(job.started for job in manager.jobs.values()),
            "queued": sum(not job.started for job in manager.jobs.values()),
        }

    @app.delete("/jobs/{job_id}", dependencies=[Depends(authorized)])
    async def cancel(job_id: UUID):
        # Idempotent: a finished or nonexistent ID needs no cancellation tombstone.
        return {"cancelled": manager.cancel(job_id)}

    @app.post("/inpaint", dependencies=[Depends(authorized)])
    async def inpaint(
        request: Request,
        image: Annotated[UploadFile, File()],
        mask: Annotated[str, Form()],
        jobId: Annotated[UUID, Form()],
    ):
        if not await asyncio.to_thread(engine.available):
            await image.close()
            raise HTTPException(503, "The local inpainting model is not configured")
        try:
            strokes = parse_mask(mask)
        except InvalidInput as error:
            await image.close()
            raise HTTPException(422, str(error)) from error
        # Admission precedes disk copying; uploads are Starlette-spooled rather than in RAM.
        if len(manager.jobs) >= settings.max_waiting + 1:
            await image.close()
            raise HTTPException(429, "Inpainting queue is full", headers={"Retry-After": "5"})
        directory = Path(tempfile.mkdtemp(prefix="job-", dir=settings.work_dir))
        submitted = False
        response_owns_directory = False
        job = None
        try:
            count = 0
            with (directory / "input").open("wb") as destination:
                while chunk := await image.read(256 * 1024):
                    count += len(chunk)
                    if count > settings.max_image_bytes:
                        raise HTTPException(413, "The image exceeds the configured size limit")
                    destination.write(chunk)
            if count == 0:
                raise HTTPException(422, "An image is required")
            try:
                job = manager.submit(jobId, directory, strokes)
                submitted = True
            except Busy as error:
                raise HTTPException(429, "Inpainting queue is full", headers={"Retry-After": "5"}) from error
            except DuplicateJob as error:
                raise HTTPException(409, "This job ID is already active") from error
            while not job.result.done():
                if await request.is_disconnected():
                    manager.cancel(jobId)
                    raise HTTPException(499, "Request cancelled")
                remaining = settings.queue_timeout - (asyncio.get_running_loop().time() - job.queued_at)
                if not job.started and remaining <= 0:
                    manager.cancel(jobId)
                    raise HTTPException(504, "Inpainting queue wait expired")
                await asyncio.wait({job.result}, timeout=0.1)
            result = job.result.result()
            if isinstance(result, CancelledJob):
                raise HTTPException(499, "Request cancelled")
            if isinstance(result, QueueTimeout):
                raise HTTPException(504, "Inpainting queue wait expired")
            if isinstance(result, InvalidInput):
                raise HTTPException(422, str(result))
            if isinstance(result, ModelUnavailable):
                raise HTTPException(503, "The local inpainting model could not process this image")
            if isinstance(result, Exception):
                raise HTTPException(500, "Inpainting failed")
            response_owns_directory = True
            return TemporaryFileResponse(result, directory)
        except asyncio.CancelledError:
            if submitted:
                manager.cancel(jobId)
            raise
        finally:
            await image.close()
            if not response_owns_directory:
                if submitted:
                    manager.cancel(jobId)
                worker_owns_directory = job is not None and manager.jobs.get(jobId) is job
                successful_result = job is not None and job.result.done() and isinstance(job.result.result(), Path)
                if not worker_owns_directory or successful_result:
                    await asyncio.to_thread(shutil.rmtree, directory, True)

    return app
