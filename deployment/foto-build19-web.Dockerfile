# Web-only overlay. Build the assets image with server/Dockerfile --target web.
# The existing production image supplies the unchanged server, CLI and plugins.
ARG FOTO_WEB_ASSETS_IMAGE=foto-build19-web-assets:local
ARG FOTO_BASE_IMAGE=foto-build18:4aa7f419

FROM ${FOTO_WEB_ASSETS_IMAGE} AS web-assets

FROM ${FOTO_BASE_IMAGE} AS runtime
ARG FOTO_BASE_IMAGE
ARG FOTO_RUNTIME_USER
ARG FOTO_WEB_SOURCE_COMMIT

# Image-building filesystem only: remove obsolete hashed Web assets, never /data.
# The owner supplies the base image's actual user and it is restored below.
USER 0
RUN test -n "${FOTO_RUNTIME_USER}" && \
    test -n "${FOTO_WEB_SOURCE_COMMIT}" && \
    rm -rf /build/www && mkdir -p /build/www
COPY --from=web-assets /usr/src/app/web/build/ /build/www/
USER ${FOTO_RUNTIME_USER}

LABEL de.opennoodle.foto.web.source-commit="${FOTO_WEB_SOURCE_COMMIT}" \
      de.opennoodle.foto.web.base-image="${FOTO_BASE_IMAGE}"

# Inherit the base image's environment, entrypoint, command, healthcheck and API
# version. Do not run set-build-version, server build or database migrations.
