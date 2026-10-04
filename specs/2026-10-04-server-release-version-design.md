# Server release metadata for custom images

The source `server/package.json` tracks the upstream server package version. It is
not necessarily the Gallery release number. `server/src/constants.ts` reads the
runtime package manifest to construct `serverVersion`; this one value feeds
`GET /api/server/version`, server About information, WebSocket version/release
events, upgrade history, APK links, and latest-release comparisons.

Official Gallery releases run `.github/actions/apply-branding` with the selected
release version before building `server/Dockerfile`. The action runs
`branding/scripts/apply-branding.sh`; its `patch_versions()` function stamps
`server/package.json` and the other release manifests. A custom Docker build that
skips that step copies the source version into its runtime image. For this source
baseline that means reporting `3.2.0`, despite shipping Gallery `5.7.1`. Image tags,
`BUILD_SOURCE_REF`, `IMMICH_SOURCE_REF`, and Compose's `IMMICH_VERSION` do not
change the reported server version.

`server/Dockerfile` now accepts `BUILD_VERSION`, and runs
`server/bin/set-build-version.mjs` against the final image's runtime
`server/package.json`. This keeps the same manifest-based reporting mechanism as
official releases; no endpoint, client compatibility rule, runtime version
override, or database schema changes are required. The official release workflow
passes its selected version as `BUILD_VERSION` too.

For a custom Gallery **5.7.1** server image, pass:

```sh
docker build -f server/Dockerfile \
  --build-arg BUILD_VERSION=5.7.1 \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_REF=work \
  --build-arg BUILD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  -t gallery-server:custom-5.7.1 .
```

`v5.7.1` is also accepted and normalized to `5.7.1`. Future semantic release
versions and prereleases (for example `6.1.0-rc.2`) use the same argument. Invalid
values fail the image build; rolling tags such as `v5` and `release` are not
release versions. No additional runtime environment variable is needed.

`BUILD_REPOSITORY` sets repository/source URLs without pretending that a custom
build is an upstream release; its default is `open-noodle/gallery`. The official
release workflow supplies its own repository. Source ref/commit and image name
remain the existing `BUILD_SOURCE_REF`, `BUILD_SOURCE_COMMIT`, and `BUILD_IMAGE`
arguments. They describe the artifact and do not override `BUILD_VERSION`.

When `BUILD_VERSION` is empty or omitted, the existing package manifest remains
unchanged. This preserves officially pre-stamped builds and provides the normal
source-package version for development images. A custom production image built
from an unstamped checkout must supply the argument; the build deliberately does
not infer a release from Git tags that may belong to the upstream repository.

After separately installing the image, the public version endpoint should return:

```sh
curl --fail --silent --show-error https://imm.lampax.top/api/server/version
# {"major":5,"minor":7,"patch":1,"prerelease":null}
```

At equal current/latest server release versions, the server's release event has
`isAvailable: false`. Mobile's compatibility helper accepts Gallery 5.x server
and app versions using its existing major-version checks. An independently newer
mobile patch version does not establish that a newer server release exists; the
mobile server-update status uses the server's known latest-release metadata when
available. Compatibility checks and notifications for actual newer releases stay
enabled.
