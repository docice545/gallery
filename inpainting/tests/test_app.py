import asyncio
import io
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from starlette.exceptions import HTTPException
from starlette.requests import ClientDisconnect
from test_engine import SolidPredictor, make_settings

from gallery_inpainting.app import RequestSizeLimit, TemporaryFileResponse, create_app
from gallery_inpainting.engine import InpaintingEngine


def image_bytes(size=(100, 80)):
    buffer = io.BytesIO()
    Image.new("RGB", size, (100, 100, 100)).save(buffer, format="PNG")
    return buffer.getvalue()


def mask_json():
    return json.dumps({"strokes": [{"points": [{"x": 0.5, "y": 0.5}], "radius": 0.1, "erase": False}]})


def payload(id=None, content=None, mask=None):
    return {
        "files": {"image": ("original.png", content or image_bytes(), "image/png")},
        "data": {"jobId": str(id or uuid4()), "mask": mask or mask_json()},
    }


def make_app(tmp_path, predictor=None, **settings_args):
    settings = make_settings(tmp_path, **settings_args)
    app = create_app(settings, InpaintingEngine(settings, predictor or SolidPredictor()))
    headers = {"Authorization": "Bearer " + settings.token}
    return app, settings, headers


def wait_for(predicate, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("Expected state did not arrive")


def test_private_auth_health_and_success_cleanup(tmp_path):
    app, settings, headers = make_app(tmp_path)
    with TestClient(app) as client:
        assert client.get("/health").status_code == 401
        assert client.get("/health", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert client.get("/health", headers=[(b"authorization", b"Bearer \xff")]).status_code == 401
        health = client.get("/health", headers=headers).json()
        assert health["ready"] and health["maxWorkingSize"] == 512 and health["device"] == "cpu"
        result = client.post("/inpaint", headers=headers, **payload())
        assert result.status_code == 200
        assert result.headers["content-type"] == "image/jpeg"
        assert result.headers["cache-control"] == "no-store"
        with Image.open(io.BytesIO(result.content)) as output:
            assert output.size == (100, 80)
        assert list(settings.work_dir.iterdir()) == []


def test_auth_rejection_precedes_multipart_parsing_or_size_limits(tmp_path):
    app, settings, _ = make_app(tmp_path, max_image_bytes=10)
    with TestClient(app) as client:
        # Missing auth takes precedence even over an invalid/oversized body declaration.
        response = client.post("/inpaint", content=b"bad", headers={"Content-Length": "999999999"})
        assert response.status_code == 401
        assert list(settings.work_dir.iterdir()) == []


def test_missing_model_returns_unavailable_without_downloading(tmp_path):
    settings = make_settings(tmp_path)
    app = create_app(settings)
    headers = {"Authorization": "Bearer " + settings.token}
    with TestClient(app) as client:
        assert client.get("/health", headers=headers).json()["ready"] is False
        assert client.post("/inpaint", headers=headers, **payload()).status_code == 503
        assert list(settings.work_dir.iterdir()) == []


@pytest.mark.parametrize("kind", ["mask", "image", "pixel_limit", "image_bytes"])
def test_invalid_request_is_rejected_and_temp_files_removed(tmp_path, kind):
    app, settings, headers = make_app(tmp_path, max_pixels=10_000, max_image_bytes=1000)
    args = payload()
    if kind == "mask":
        args = payload(mask='{"strokes":[]}')
    elif kind == "image":
        args = payload(content=b"invalid image")
    elif kind == "pixel_limit":
        args = payload(content=image_bytes((101, 100)))
    elif kind == "image_bytes":
        args = payload(content=b"x" * 1001)
    with TestClient(app) as client:
        assert client.post("/inpaint", headers=headers, **args).status_code == (413 if kind == "image_bytes" else 422)
        wait_for(lambda: list(settings.work_dir.iterdir()) == [])


def test_declared_request_limit_is_enforced_before_parsing(tmp_path):
    app, _, headers = make_app(tmp_path, max_image_bytes=1000)
    with TestClient(app) as client:
        response = client.post("/inpaint", content=b"", headers={**headers, "Content-Length": "999999999"})
        assert response.status_code == 413


def test_cancel_idempotent_and_job_id_validation(tmp_path):
    app, _, headers = make_app(tmp_path)
    with TestClient(app) as client:
        assert client.delete(f"/jobs/{uuid4()}", headers=headers).json() == {"cancelled": False}
        assert client.delete("/jobs/invalid", headers=headers).status_code == 422


class BlockingPredictor(SolidPredictor):
    def __init__(self):
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()
        self.running = 0
        self.max_running = 0

    def predict(self, image, mask):
        self.running += 1
        self.max_running = max(self.max_running, self.running)
        self.entered.set()
        assert self.release.wait(10), "Test failed to release native inference"
        try:
            return super().predict(image, mask)
        finally:
            self.running -= 1


def test_cancelled_native_job_holds_slot_until_finish_and_next_job_is_serial(tmp_path):
    predictor = BlockingPredictor()
    app, settings, headers = make_app(tmp_path, predictor)
    id = uuid4()
    with TestClient(app) as client, ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, "/inpaint", headers=headers, **payload(id))
        assert predictor.entered.wait(3)
        try:
            assert client.delete(f"/jobs/{id}", headers=headers).json() == {"cancelled": True}
            assert first.result(timeout=3).status_code == 499
            second = pool.submit(client.post, "/inpaint", headers=headers, **payload())
            wait_for(lambda: len(app.state.manager.jobs) == 2)
            assert predictor.running == 1
            assert list(settings.work_dir.iterdir())
            assert client.get("/health", headers=headers).json()["active"] == 1
        finally:
            predictor.release.set()
        assert second.result(timeout=5).status_code == 200
        assert predictor.max_running == 1
        wait_for(lambda: not list(settings.work_dir.iterdir()))


def test_queue_bound_and_duplicate_job_ids(tmp_path):
    predictor = BlockingPredictor()
    app, _, headers = make_app(tmp_path, predictor, max_waiting=1)
    id = uuid4()
    with TestClient(app) as client, ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, "/inpaint", headers=headers, **payload(id))
        assert predictor.entered.wait(3)
        try:
            assert client.post("/inpaint", headers=headers, **payload(id)).status_code == 409
            second = pool.submit(client.post, "/inpaint", headers=headers, **payload())
            wait_for(lambda: len(app.state.manager.jobs) == 2)
            response = client.post("/inpaint", content=b"not multipart", headers=headers)
            assert response.status_code == 429
        finally:
            predictor.release.set()
        assert first.result(timeout=5).status_code == second.result(timeout=5).status_code == 200


def test_queue_timeout_discards_queued_original(tmp_path):
    predictor = BlockingPredictor()
    app, settings, headers = make_app(tmp_path, predictor, queue_timeout=1)
    with TestClient(app) as client, ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, "/inpaint", headers=headers, **payload())
        assert predictor.entered.wait(3)
        try:
            second = pool.submit(client.post, "/inpaint", headers=headers, **payload())
            assert second.result(timeout=3).status_code == 504
            assert len(predictor.calls) == 0
        finally:
            predictor.release.set()
        assert first.result(timeout=5).status_code == 200
        wait_for(lambda: not list(settings.work_dir.iterdir()))
        assert len(predictor.calls) == 1


def test_idle_unload_and_startup_orphan_reaping(tmp_path):
    predictor = SolidPredictor()
    app, settings, headers = make_app(tmp_path, predictor, idle_unload_seconds=1)
    settings.work_dir.mkdir(parents=True)
    orphan = settings.work_dir / "job-orphan"
    orphan.mkdir()
    (orphan / "input").write_bytes(b"private")
    preserved = settings.work_dir / "do-not-touch"
    preserved.mkdir()
    with TestClient(app) as client:
        assert not orphan.exists()
        assert preserved.exists()
        assert client.post("/inpaint", headers=headers, **payload()).status_code == 200
        wait_for(lambda: predictor.unloads > 0, timeout=3)


@pytest.mark.parametrize("error", [OSError("receiver closed"), asyncio.CancelledError()])
def test_response_cleanup_when_client_disconnects_during_file_transfer(tmp_path, error):
    directory = tmp_path / "job-result"
    directory.mkdir()
    file = directory / "result.jpg"
    file.write_bytes(b"result")
    response = TemporaryFileResponse(file, directory)

    async def exercise():
        async def receive():
            return {"type": "http.disconnect"}

        async def send(message):
            if message["type"] == "http.response.body":
                raise error

        scope = {"type": "http", "method": "GET", "headers": [], "asgi": {"spec_version": "2.4"}}
        with pytest.raises((OSError, asyncio.CancelledError, ClientDisconnect)):
            await response(scope, receive, send)

    asyncio.run(exercise())
    assert not directory.exists()


def test_chunked_request_size_limit_does_not_trust_content_length():
    async def exercise():
        async def receive():
            return {"type": "http.request", "body": b"x" * 101, "more_body": True}

        async def send(message):
            pass

        async def app(scope, receive, send):
            await receive()

        middleware = RequestSizeLimit(app, limit=100)
        with pytest.raises(HTTPException) as error:
            await middleware({"type": "http", "headers": []}, receive, send)
        assert error.value.status_code == 413

    asyncio.run(exercise())


def test_settings_reject_unsafe_configuration(tmp_path):
    for kwargs in (
        {"cpu_threads": 5},
        {"max_waiting": 4},
        {"max_working_size": 4096},
        {"model_sha256": "bad"},
        {"max_pixels": 36_000_001},
    ):
        with pytest.raises(ValueError):
            make_settings(tmp_path, **kwargs)
