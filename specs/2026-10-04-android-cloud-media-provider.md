# Android cloud Photo Picker integration

Research date: 2026-10-04. This is a feasibility assessment for the custom,
sideloaded Android application `de.opennoodle.gallery`; it does not implement a
provider or establish device support.

## Decision

Do not add a CloudMediaProvider to this fork as a purported working integration.
The public API permits an ordinary application to declare a provider, but this
does **not** grant admission to the system Photo Picker's cloud-provider list.
The examined Android platform implementation normally enforces a platform
allowlist. A sideload alone does not add `de.opennoodle.gallery` to that list.
There is no verified public, ordinary-app operation that adds this package to
the allowlist or selects it despite the allowlist.

Consequently, we cannot promise that this application will expose its server
library in the stock Samsung system Photo Picker without platform approval or
integration. This is a restriction on normal platform admission, not a claim
that no test device or modified Android configuration could ever run a provider.
No rooting, shell override, DeviceConfig modification, fake MediaStore entries,
or background library mirror is part of the proposed product workflow.

The practical workflows remain:

- Share from Photos: obtain an original in temporary application cache and use
  the system share sheet, without importing that temporary copy into MediaStore.
- Download to device: explicitly save the original to the native media library,
  making it available to applications that enumerate local media.

## Public API and platform gates

| Question                            | Verified result                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public API                          | `android.provider.CloudMediaProvider` and `CloudMediaProviderContract`. Both are present in the Android 13 public API surface, API 33. They are absent from the examined Android 12/API 31 surface.                                                                                                                                                                                                                                     |
| Minimum for a direct implementation | Gate use of these framework classes on Android 13/API 33 or later. Cloud functionality also depends on the installed MediaProvider/Photo Picker implementation and configuration; an Android version number alone does not establish availability. The separate existence/backport of a local Photo Picker does not prove cloud-provider admission.                                                                                     |
| Manifest registration               | An exported provider with its own authority and the `android.content.action.CLOUD_MEDIA_PROVIDER` intent filter; its permission must be `com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS`.                                                                                                                                                                                                                          |
| Signature permission                | MediaProvider declares that permission as `signature`. It protects access **to** the provider by the system. An ordinary provider application can require that permission on its component without itself being platform-signed or holding it. It does not grant the application permission to configure the system picker.                                                                                                             |
| Admission                           | `CloudProviderUtils.getAvailableCloudProvidersInternal()` checks the required provider read permission and, when enforcement is enabled, requires the provider's **package name** in `ConfigStore.getAllowedCloudProviderPackages()`.                                                                                                                                                                                                   |
| Platform configuration              | The examined implementation uses DeviceConfig namespace `mediaprovider`, keys `allowed_cloud_providers`, `cloud_media_feature_enabled`, and `cloud_media_enforce_provider_allowlist`. Allowlist enforcement defaults to `true`. Cloud queries also require an enabled feature flag and a nonempty configured allowlist. These are system policy controls, not application settings.                                                     |
| Provider selection                  | Normal selection applies the allowlist. `MediaProvider.getResultForSetCloudProvider()` accepts its own UID or the shell; other callers receive `SecurityException`. A shell-only test override is not a public application integration mechanism.                                                                                                                                                                                       |
| Number of selected sources          | The examined controller tracks one selected cloud-provider authority alongside the local provider. Installing another provider does not automatically select it.                                                                                                                                                                                                                                                                        |
| Google Play / certification         | AOSP's discovery checks do not examine Play installation, purchase, or a certification token. Publishing in Google Play therefore cannot be claimed sufficient, and this source does not prove that Play distribution is intrinsically required. Any commercial onboarding/certification and platform allowlist admission must be established separately with the platform operator. No approval for this package has been established. |
| Samsung / One UI                    | Device model, Android/One UI version, installed picker/module and platform policy matter. No Samsung device was available and no evidence establishes that Samsung admits this sideloaded package. Support cannot be inferred from compiling against SDK 36.                                                                                                                                                                            |

The allowlist behavior is present in the examined Android 14 source as well as
the current AOSP MediaProvider source; it is not just a missing Flutter plugin.
Changing the application ID would not establish platform admission and is outside
this task.

## How an admitted provider would work

The contract exposes paged metadata/media/album queries, collection identifiers
and sync generations, deleted-item queries, previews, and `onOpenMedia()` with
a `CancellationSignal` and `ParcelFileDescriptor`. It can describe a remote
library without storing a full set of original files in MediaStore. Originals
can be obtained when requested; preview requests and metadata synchronization
still need their own conservative caching and account/authentication handling.
Provider implementation would therefore require native Android lifecycle,
metadata synchronization, authentication, cancellation, streaming and URI
permission work, in addition to obtaining actual platform admission.

Apps do not directly consume a cloud provider. The framework contract directs
them through the system `MediaStore.ACTION_PICK_IMAGES` UI. The picker grants
the requesting app access to specifically selected media URIs. A receiver using
its own MediaStore picker will not discover server-only assets just because a
cloud provider exists.

This distinction applies to Telegram: cloud media could be offered only when
the particular Telegram version and entry point actually invokes a supporting
system Photo Picker, and only if Photos were an admitted, selected provider.
Its own album selector is a different path. Neither Telegram's actual picker
choice on the user's Samsung nor provider admission has been tested here.

An `ACTION_GET_CONTENT`/DocumentsProvider integration is also a separate API;
it is not proof of CloudMediaProvider integration. The current Android manifest
in this fork declares media share/view entry points, not a CloudMediaProvider.

## Device verification boundaries

Record the Samsung model, Android version, One UI version and installed system
Photo Picker/module before assessing cloud support. Inspect the picker's cloud
source settings through its normal UI. The presence of Google Photos, Samsung
Gallery, or another admitted service is not evidence that arbitrary sideloaded
packages can join the list.

For this fork, validate the supported Share/Save paths instead: a server-only
photo, large video and mixed selection; progress and cancellation; offline and
server failures; whether the receiving app can still read a shared temporary
file; whether Share leaves the local media library unchanged; and whether Save
creates an ordinary local media entry without repeating an existing download.
Also verify Samsung Motion Photo and Apple-origin Live Photo handling separately:
a still image and a separate video must not be presented as proof of a native
Samsung Motion Photo file or native PhotoKit paired resource.

No APK build, physical Samsung/Telegram test, OEM provider approval, native
provider registration, or system picker selection test was performed as part of
this research. No provider is added to this change.

## Sources and reproducibility

The source below was retrieved from the official AOSP GitHub mirrors through
the configured environment proxy. Current-source citations are pinned to
MediaProvider commit `a183e2b92c71d86ec7b104c116ef3f4dbcbb523f` rather than relying
on a moving branch. The API/version comparison uses Android release tags.

1. [Android 13 public API surface](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-13.0.0_r1/apex/framework/api/current.txt): public classes, queries, original file descriptor and cancellation signatures.
2. [Android 12 public API surface](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-12.0.0_r1/apex/framework/api/current.txt): comparison before API 33.
3. [CloudMediaProvider contract and manifest example](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/apex/framework/java/android/provider/CloudMediaProvider.java): exported provider protection and system-picker-only access.
4. [CloudMediaProviderContract](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/apex/framework/java/android/provider/CloudMediaProviderContract.java): provider intent and required access permission.
5. [MediaProvider manifest](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/AndroidManifest.xml): signature permission declaration.
6. [CloudProviderUtils](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/src/com/android/providers/media/photopicker/util/CloudProviderUtils.java): discovery and package allowlist filtering.
7. [ConfigStore](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/src/com/android/providers/media/ConfigStore.java): DeviceConfig keys, enablement and default enforcement.
8. [PickerSyncController](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/src/com/android/providers/media/photopicker/PickerSyncController.java): normal selected-provider validation versus explicit test override.
9. [MediaProvider selection gate](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/a183e2b92c71d86ec7b104c116ef3f4dbcbb523f/src/com/android/providers/media/MediaProvider.java): `getResultForSetCloudProvider()` accepts own UID or shell.
10. [Android 14 selection behavior](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/android-14.0.0_r1/src/com/android/providers/media/photopicker/PickerSyncController.java): release-tag comparison of allowlist handling.

The Android reference pages are useful entry points for a future approved
implementation: [CloudMediaProvider](https://developer.android.com/reference/android/provider/CloudMediaProvider),
[CloudMediaProviderContract](https://developer.android.com/reference/android/provider/CloudMediaProviderContract),
and [Photo Picker](https://developer.android.com/training/data-storage/shared/photopicker).
This environment allowed retrieval of the AOSP mirror sources; commercial
integration terms and Samsung-specific allowlists were not independently
verified from those reference pages.

## Проверка продолжения мобильной задачи, 6 октября 2026

Повторно проверен более новый release source Android 16/QPR1:
`android-16.0.0_r3`, commit `78a0bebdc478a3e827618944f9998c5e21fc9712`.
Ранее проверенный mirror `main` не обновлялся после 10 марта 2025 года,
поэтому его нельзя называть подтверждением всех текущих OEM реализаций.

В Android 16 restriction сохраняется:

- [CloudProviderUtils, строки 145–152](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/photopicker/util/CloudProviderUtils.java#L145-L152)
  исключает package, отсутствующий в allowlist, при discovery.
- [ConfigStore, строка 74](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/ConfigStore.java#L74)
  задаёт `DEFAULT_ENFORCE_CLOUD_PROVIDER_ALLOWLIST = true`;
  [строки 376–389](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/ConfigStore.java#L376-L389)
  требуют непустую allowlist для feature-enabled.
- [PickerSyncController, строки 539–542](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/photopicker/PickerSyncController.java#L539-L542)
  сохраняет эту проверку при обычном выборе provider.
- [MediaProvider, строки 8032–8043](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/MediaProvider.java#L8032-L8043)
  допускает служебный selection request только от собственного UID или shell.

Публичный provider contract реализуем обычным приложением: permission защищает
доступ **к provider**, а не требует platform signature от самого приложения.
Но manifest/provider implementation не даёт sideloaded `de.opennoodle.gallery`
допуск в системный список. Без официального допуска платформы/OEM добавлять
provider сейчас недостаточно для цели пользователя; fake provider и overrides
системной безопасности не реализованы. Наличие только Google/None на Samsung
согласуется с gate, но конкретная Samsung allowlist здесь не проверена.

API существует с Android 13/API 33; наличие класса не равно доступности cloud
источника в конкретном Photo Picker module/OEM. Прямой `developer.android.com`
в этой среде вернул proxy tunnel HTTP 403, поэтому ограничения подтверждены
официальным AOSP release source, а не неподтверждёнными условиями сертификации.
Новые Samsung policy и более поздние недоступные mirror releases остаются
границей проверки. Основные рабочие сценарии — Share original из «Фото» через
временный cache и Download original в MediaStore — сохранены.
