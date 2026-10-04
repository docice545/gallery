import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';

RemoteAsset _remote(String id, {bool live = true, AssetType type = AssetType.image}) => RemoteAsset(
  id: id,
  name: '$id.jpg',
  checksum: id,
  ownerId: 'owner',
  type: type,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  livePhotoVideoId: live ? '$id-motion' : null,
  isEdited: false,
);

LocalAsset _localLive(String id, {AssetType type = AssetType.image}) => LocalAsset(
  id: id,
  name: '$id.heic',
  type: type,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  playbackStyle: AssetPlaybackStyle.livePhoto,
  isEdited: false,
);

LivePhotoCandidate _candidate(Object token, {BaseAsset? asset, double visibility = 1, double distance = 0}) =>
    LivePhotoCandidate(
      token: token,
      asset: asset ?? _remote('$token'),
      visibleFraction: visibility,
      distanceFromCenter: distance,
    );

void main() {
  group('live photo geometry and candidate choice', () {
    test('uses visible tile area, including horizontal clipping and empty/offscreen rectangles', () {
      const viewport = Rect.fromLTWH(0, 0, 100, 100);
      expect(livePhotoVisibleFraction(const Rect.fromLTWH(0, 20, 100, 100), viewport), 0.8);
      expect(livePhotoVisibleFraction(const Rect.fromLTWH(50, 50, 100, 100), viewport), 0.25);
      expect(livePhotoVisibleFraction(const Rect.fromLTWH(10, 10, 20, 20), viewport), 1);
      expect(livePhotoVisibleFraction(const Rect.fromLTWH(100, 100, 20, 20), viewport), 0);
      expect(livePhotoVisibleFraction(Rect.zero, viewport), 0);
      expect(livePhotoVisibleFraction(viewport, Rect.zero), 0);
    });

    test('80 percent is sufficient, less and invalid geometry are excluded', () {
      expect(chooseLivePhotoCandidate([_candidate('under', visibility: 0.799)]), isNull);
      expect(chooseLivePhotoCandidate([_candidate('threshold', visibility: 0.8)])?.token, 'threshold');
      expect(
        chooseLivePhotoCandidate([
          _candidate('nan', visibility: double.nan),
          _candidate('infinity', visibility: double.infinity),
          _candidate('bad-distance', distance: double.nan),
        ]),
        isNull,
      );
    });

    test('chooses one most visible candidate and uses centre distance to break ties', () {
      final candidates = [
        _candidate('partial-near', visibility: 0.9),
        _candidate('full-far', distance: 100),
        _candidate('full-near', distance: 10),
      ];
      expect(chooseLivePhotoCandidate(candidates)?.token, 'full-near');
      expect(chooseLivePhotoCandidate(candidates.reversed)?.token, 'full-near');
    });

    test('keeps the active tile until its visibility drops below the threshold', () {
      expect(
        chooseLivePhotoCandidate([
          _candidate('new-centre'),
          _candidate('active', visibility: 0.8, distance: 100),
        ], activeToken: 'active')?.token,
        'active',
      );
      expect(
        chooseLivePhotoCandidate([
          _candidate('active', visibility: 0.79),
          _candidate('new-centre'),
        ], activeToken: 'active')?.token,
        'new-centre',
      );
    });

    test('ordinary photos, videos, animated images and malformed video relations do not qualify', () {
      final ordinary = _remote('photo', live: false);
      final video = _remote('video', type: AssetType.video);
      final animated = _remote('animated', live: false).copyWith(durationMs: 1000);
      final malformedLocalVideo = _localLive('malformed', type: AssetType.video);
      expect(
        chooseLivePhotoCandidate([
          _candidate('photo', asset: ordinary),
          _candidate('video', asset: video),
          _candidate('animated', asset: animated),
          _candidate('malformed', asset: malformedLocalVideo),
        ]),
        isNull,
      );
    });

    test('server-linked Samsung/Apple photos and local PhotoKit live photos use the same model', () {
      final samsung = _remote('samsung');
      final appleRemote = _remote('apple');
      final appleLocal = _localLive('apple-local');
      for (final asset in [samsung, appleRemote, appleLocal]) {
        expect(asset.isMotionPhoto, isTrue);
        expect(chooseLivePhotoCandidate([_candidate(asset.id, asset: asset)])?.asset, same(asset));
      }
    });
  });

  group('single live photo playback lease', () {
    test('grants one lease after 350 ms, without extending delay for stable measurements', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        var notifications = 0;
        controller.addListener(() => notifications++);
        controller.updateCandidates([_candidate('first'), _candidate('second', distance: 10)]);
        clock.elapse(const Duration(milliseconds: 200));
        controller.updateCandidates([_candidate('first'), _candidate('second', distance: 10)]);
        clock.elapse(const Duration(milliseconds: 149));
        expect(controller.activeToken, isNull);
        expect(notifications, 0);
        clock.elapse(const Duration(milliseconds: 1));
        expect(controller.activeToken, 'first');
        expect(notifications, 1);
        controller.dispose();
      });
    });

    test('a changed pending candidate must settle for its own full delay', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        controller.updateCandidates([_candidate('first')]);
        clock.elapse(const Duration(milliseconds: 300));
        controller.updateCandidates([_candidate('second')]);
        clock.elapse(const Duration(milliseconds: 349));
        expect(controller.activeToken, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(controller.activeToken, 'second');
        controller.dispose();
      });
    });

    test('scroll starts stop playback immediately and suppress both pending and active work', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        controller.updateCandidates([_candidate('first')]);
        clock.elapse(const Duration(milliseconds: 100));
        controller.setScrolling(true);
        clock.elapse(const Duration(seconds: 1));
        expect(controller.activeToken, isNull);
        controller.setScrolling(false);
        clock.elapse(livePhotoSettlingDelay);
        expect(controller.activeToken, 'first');
        controller.setScrolling(true);
        expect(controller.activeToken, isNull);
        controller.updateCandidates([_candidate('second')]);
        clock.elapse(const Duration(seconds: 1));
        expect(controller.activeToken, isNull);
        controller.setScrolling(false);
        clock.elapse(livePhotoSettlingDelay);
        expect(controller.activeToken, 'second');
        controller.dispose();
      });
    });

    test('loss of sufficient visibility stops the active lease without playing every other tile', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        controller.updateCandidates([_candidate('first')]);
        clock.elapse(livePhotoSettlingDelay);
        controller.updateCandidates([_candidate('first', visibility: 0.79), _candidate('second')]);
        expect(controller.activeToken, isNull);
        clock.elapse(const Duration(seconds: 2));
        expect(controller.activeToken, isNull);
        controller.dispose();
      });
    });

    test('disabled setting cancels pending timers and releases active playback immediately', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController(enabled: false);
        controller.updateCandidates([_candidate('first')]);
        clock.elapse(const Duration(seconds: 1));
        expect(controller.activeToken, isNull);
        controller.setEnabled(true);
        clock.elapse(const Duration(milliseconds: 100));
        controller.setEnabled(false);
        clock.elapse(const Duration(seconds: 1));
        expect(controller.activeToken, isNull);
        controller.setEnabled(true);
        clock.elapse(livePhotoSettlingDelay);
        expect(controller.activeToken, 'first');
        controller.setEnabled(false);
        expect(controller.activeToken, isNull);
        controller.dispose();
      });
    });

    test('completion/errors restore the photo and do not replay or walk through the viewport', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        controller.updateCandidates([_candidate('first'), _candidate('second', distance: 10)]);
        clock.elapse(livePhotoSettlingDelay);
        controller.complete('wrong-token');
        expect(controller.activeToken, 'first');
        controller.complete('first');
        expect(controller.activeToken, isNull);
        controller.updateCandidates([_candidate('first'), _candidate('second')]);
        clock.elapse(const Duration(seconds: 5));
        expect(controller.activeToken, isNull);
        controller.setScrolling(true);
        controller.setScrolling(false);
        clock.elapse(livePhotoSettlingDelay);
        expect(controller.activeToken, 'first');
        controller.dispose();
      });
    });

    test('unregister cancels pending playback and immediately releases an active tile', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        controller.updateCandidates([_candidate('pending')]);
        controller.unregister('pending');
        clock.elapse(const Duration(seconds: 1));
        expect(controller.activeToken, isNull);
        controller.updateCandidates([_candidate('active')]);
        clock.elapse(livePhotoSettlingDelay);
        expect(controller.activeToken, 'active');
        controller.unregister('active');
        expect(controller.activeToken, isNull);
        controller.dispose();
      });
    });

    test('dispose cancels pending timers and late completion/scroll callbacks are inert', () {
      fakeAsync((clock) {
        final controller = LivePhotoAutoplayController();
        var notifications = 0;
        controller.addListener(() => notifications++);
        controller.updateCandidates([_candidate('pending')]);
        controller.dispose();
        controller.complete('pending');
        controller.setScrolling(false);
        controller.setEnabled(true);
        controller.updateCandidates([_candidate('late')]);
        clock.elapse(const Duration(seconds: 2));
        expect(controller.activeToken, isNull);
        expect(notifications, 0);
        expect(clock.nonPeriodicTimerCount, 0);
      });
    });
  });
}
