import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A transport becoming available is a retry opportunity, not proof that the
/// backend is reachable. Share one subscription and never poll per thumbnail.
final networkTransportAvailableProvider = StreamProvider.autoDispose<bool>((ref) {
  return Connectivity().onConnectivityChanged
      .map((transports) => transports.any((transport) => transport != ConnectivityResult.none))
      .distinct();
});
