import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/pages/common/download_panel.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';

import '../test_utils.dart';
import '../widget_tester_extensions.dart';

void main() {
  setUpAll(TestUtils.init);

  testWidgets('successful pair explicitly says motion was preserved', (tester) async {
    await tester.pumpConsumerWidget(
      DownloadTaskTile(
        progress: 1,
        fileName: 'photo.HEIC',
        status: TaskStatus.complete,
        livePhotoOutcome: LivePhotoSaveOutcome.livePhoto,
        onCancelDownload: () {},
      ),
    );
    expect(find.text(StaticTranslations.instance.download_live_photo_preserved), findsOneWidget);
    expect(find.text(StaticTranslations.instance.download_live_photo_image_only), findsNothing);
  });

  testWidgets('fallback explicitly says saved photo has no motion', (tester) async {
    await tester.pumpConsumerWidget(
      DownloadTaskTile(
        progress: 1,
        fileName: 'photo.HEIC',
        status: TaskStatus.complete,
        livePhotoOutcome: LivePhotoSaveOutcome.imageOnly,
        onCancelDownload: () {},
      ),
    );
    expect(find.text(StaticTranslations.instance.download_live_photo_image_only), findsOneWidget);
    expect(find.text(StaticTranslations.instance.download_live_photo_preserved), findsNothing);
  });

  testWidgets('ordinary still keeps the existing completion text', (tester) async {
    await tester.pumpConsumerWidget(
      DownloadTaskTile(progress: 1, fileName: 'photo.jpg', status: TaskStatus.complete, onCancelDownload: () {}),
    );
    expect(find.text(StaticTranslations.instance.download_complete), findsOneWidget);
    expect(find.text(StaticTranslations.instance.download_live_photo_preserved), findsNothing);
  });

  testWidgets('failed or cancelled pair never claims preserved motion', (tester) async {
    for (final status in [TaskStatus.failed, TaskStatus.canceled]) {
      await tester.pumpConsumerWidget(
        DownloadTaskTile(
          progress: .8,
          fileName: 'photo.HEIC',
          status: status,
          livePhotoOutcome: LivePhotoSaveOutcome.failed,
          onCancelDownload: () {},
        ),
      );
      expect(find.text(StaticTranslations.instance.download_live_photo_preserved), findsNothing);
      expect(find.text(StaticTranslations.instance.download_live_photo_image_only), findsNothing);
    }
  });
}
