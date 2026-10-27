import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/offline_thumbnail_warmup.dart';

void main() {
  group('offline thumbnail prefetch network policy', () {
    test('blocks every transport when fully disconnected', () {
      expect(canWarmThumbnailsOn(const []), false);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.none]), false);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.none], allowAnyNetwork: true), false);
    });

    test('defaults to Wi-Fi and never silently uses cellular', () {
      expect(canWarmThumbnailsOn(const [ConnectivityResult.wifi]), true);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.mobile]), false);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.vpn]), false);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.ethernet]), false);
    });

    test('explicit any-network preference accepts mobile, VPN and ethernet', () {
      expect(canWarmThumbnailsOn(const [ConnectivityResult.mobile], allowAnyNetwork: true), true);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.vpn], allowAnyNetwork: true), true);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.ethernet], allowAnyNetwork: true), true);
      expect(canWarmThumbnailsOn(const [ConnectivityResult.wifi], allowAnyNetwork: true), true);
    });

    test('Wi-Fi present is sufficient if another transport is also reported', () {
      expect(
        canWarmThumbnailsOn(const [ConnectivityResult.mobile, ConnectivityResult.wifi]),
        true,
      );
    });
  });
}
