import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:mocktail/mocktail.dart';

class _TimelineRepository extends Mock implements TimelineRepository {}

class _SettingsRepository extends Mock implements SettingsRepository {}

void main() {
  test('Live Photos factory forwards viewer, partners, scope and grouping without a separate asset model', () async {
    final repository = _TimelineRepository();
    final settings = _SettingsRepository();
    when(() => settings.appConfig).thenReturn(const AppConfig());
    const scope = TimelineTemporalScope.year(2025);
    when(
      () => repository.livePhotos(['viewer', 'partner'], 'viewer', GroupAssetsBy.month, temporalScope: scope),
    ).thenReturn((
      bucketSource: () => const Stream.empty(),
      assetSource: (_, _) async => [],
      origin: TimelineOrigin.livePhotos,
    ));

    final factory = TimelineFactory(timelineRepository: repository, settingsRepository: settings);
    final service = factory.livePhotos(
      ['viewer', 'partner'],
      'viewer',
      groupBy: GroupAssetsBy.month,
      temporalScope: scope,
    );
    expect(service.origin, TimelineOrigin.livePhotos);
    verify(
      () => repository.livePhotos(['viewer', 'partner'], 'viewer', GroupAssetsBy.month, temporalScope: scope),
    ).called(1);
    await service.dispose();
  });
}
