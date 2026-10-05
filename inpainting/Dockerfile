FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OMP_NUM_THREADS=2 \
    MKL_NUM_THREADS=2 \
    INPAINTING_MODEL_PATH=/models/big-lama.pt \
    INPAINTING_WORK_DIR=/tmp/gallery-inpainting

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir torch==2.10.0 --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir -r requirements.txt \
    && groupadd --gid 1000 inpainting \
    && useradd --uid 1000 --gid 1000 --no-create-home inpainting
COPY --chown=1000:1000 gallery_inpainting ./gallery_inpainting
USER 1000:1000

# One process is mandatory: multiple Uvicorn workers bypass the global job limit.
CMD ["uvicorn", "gallery_inpainting.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "3004", "--workers", "1", "--no-access-log"]
