# Backend-only overlay; the existing server Dockerfile built this assets image.
ARG FOTO_BACKEND_ASSETS_IMAGE=foto-post19-backend-assets:local
ARG FOTO_BASE_IMAGE=foto-build19-web:e2a95e6
FROM ${FOTO_BACKEND_ASSETS_IMAGE} AS backend-assets
FROM ${FOTO_BASE_IMAGE} AS runtime

ARG FOTO_BASE_IMAGE
ARG FOTO_RUNTIME_USER
ARG FOTO_BASE_ID
ARG FOTO_BACKEND_SOURCE_COMMIT
ARG FOTO_BUILD_ID
ARG FOTO_IMAGE_TAG
ARG FOTO_API_VERSION=5.7.3

USER 0
# Compare deployed manifests: pnpm deploy resolves workspace/range dependencies,
# so the raw builder package.json is not comparable with the existing runtime.
# Preserve the runtime dependencies; no npm/pnpm operation runs in this stage.
COPY --from=backend-assets /output/server-pruned/package.json /tmp/foto-backend-source-package.json
RUN test -n "${FOTO_RUNTIME_USER}" && \
    test -n "${FOTO_BASE_ID}" && \
    test -n "${FOTO_BACKEND_SOURCE_COMMIT}" && \
    test -n "${FOTO_BUILD_ID}" && \
    test -n "${FOTO_IMAGE_TAG}" && \
    node -e 'const a=require("node:assert/strict"),f=require("node:fs");const old=JSON.parse(f.readFileSync("/usr/src/app/server/package.json","utf8"));const next=JSON.parse(f.readFileSync("/tmp/foto-backend-source-package.json","utf8"));a.equal(old.version,process.argv[1]);a.equal(next.version,process.argv[1]);for(const k of ["dependencies","optionalDependencies","peerDependencies","type","main","exports"]){a.deepEqual(next[k],old[k],`Runtime manifest mismatch: ${k}`)}' "${FOTO_API_VERSION}" && \
    rm /tmp/foto-backend-source-package.json && \
    rm -rf /usr/src/app/server/dist && \
    mkdir -p /usr/src/app/server/dist

COPY --from=backend-assets /usr/src/app/server/dist/ /usr/src/app/server/dist/
RUN test -f /usr/src/app/server/dist/main.js && \
    test -f /usr/src/app/server/dist/schema/migrations/1776735180298-ChangeDurationToInteger.js && \
    test -f /usr/src/app/server/dist/schema/migrations/1793000000000-ClearPreOptionMFaceRepairScans.js && \
    node /usr/src/app/server/bin/set-build-version.mjs "${FOTO_API_VERSION}"

# Empty base Config.User means root; the owner's preflight normalizes it to 0.
USER ${FOTO_RUNTIME_USER}
ENV IMMICH_BUILD=${FOTO_BUILD_ID} \
    IMMICH_BUILD_IMAGE=${FOTO_IMAGE_TAG} \
    IMMICH_BUILD_URL=https://github.com/docice545/gallery/commit/${FOTO_BACKEND_SOURCE_COMMIT} \
    IMMICH_SOURCE_COMMIT=${FOTO_BACKEND_SOURCE_COMMIT} \
    IMMICH_SOURCE_REF=codex/foto-post-build19-asset-consistency \
    IMMICH_SOURCE_URL=https://github.com/docice545/gallery/commit/${FOTO_BACKEND_SOURCE_COMMIT} \
    IMMICH_REPOSITORY=docice545/gallery \
    IMMICH_REPOSITORY_URL=https://github.com/docice545/gallery

LABEL de.opennoodle.foto.backend.source-commit="${FOTO_BACKEND_SOURCE_COMMIT}" \
      de.opennoodle.foto.backend.base-image-id="${FOTO_BASE_ID}" \
      de.opennoodle.foto.backend.base-image="${FOTO_BASE_IMAGE}" \
      de.opennoodle.foto.backend.api-version="${FOTO_API_VERSION}"
# Inherit the actual base entrypoint, command, healthcheck, workdir, volumes,
# exposed ports and all other runtime configuration. Never start the server here.
