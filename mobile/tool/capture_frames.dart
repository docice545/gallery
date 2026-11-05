// Standalone Dart SDK tool; connects only to the user's local profile VM service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) {
    stderr.writeln('dart run tool/capture_frames.dart VM_HTTP_URI SCENARIO SECONDS SOURCE_SHA OUTPUT.json');
    exitCode = 2;
    return;
  }
  final [address, scenario, secondsText, sha, output] = arguments;
  final seconds = int.parse(secondsText);
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sha) ||
      seconds < 5 ||
      seconds > 180 ||
      !RegExp(r'^[a-z0-9_-]+$').hasMatch(scenario)) {
    throw ArgumentError('Use a full source SHA, scenario identifier and 5–180 seconds');
  }
  final uri = Uri.parse(address);
  if (!['127.0.0.1', 'localhost', '::1'].contains(uri.host) || uri.scheme != 'http') {
    throw ArgumentError('Use the loopback HTTP VM service address printed by flutter run --profile');
  }
  final socket = await WebSocket.connect(
    uri.replace(scheme: 'ws', path: '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws').toString(),
  );
  var sequence = 0;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  socket.listen(
    (message) {
      final value = jsonDecode(message as String) as Map<String, dynamic>;
      final waiter = pending.remove(value['id']);
      if (waiter != null) {
        if (value.containsKey('error')) {
          waiter.completeError(StateError('${value['error']}'));
        } else {
          waiter.complete(value['result'] as Map<String, dynamic>);
        }
      }
    },
    onDone: () {
      for (final waiter in pending.values) {
        waiter.completeError(StateError('VM service disconnected; capture incomplete'));
      }
      pending.clear();
    },
  );
  Future<Map<String, dynamic>> rpc(String method, [Map<String, Object> parameters = const {}]) {
    final id = ++sequence;
    final result = Completer<Map<String, dynamic>>();
    pending[id] = result;
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': parameters}));
    return result.future.timeout(const Duration(seconds: 15));
  }

  try {
    final vm = await rpc('getVM');
    String? isolate;
    for (final reference in vm['isolates'] as List) {
      final detail = await rpc('getIsolate', {'isolateId': reference['id'] as String});
      if ((detail['extensionRPCs'] as List? ?? []).contains('ext.foto.frames')) {
        if (isolate != null) {
          throw StateError('More than one FOTO capture isolate');
        }
        isolate = reference['id'] as String;
      }
    }
    if (isolate == null) {
      throw StateError('Start the reviewed app with --profile --dart-define=FOTO_FRAME_CAPTURE=true');
    }
    final started = DateTime.now().toUtc().toIso8601String();
    await rpc('ext.foto.frames', {'isolateId': isolate, 'action': 'start', 'hz': '120'});
    stdout.writeln('RECORDING $scenario for $seconds seconds; perform the documented gestures now.');
    await Future<void>.delayed(Duration(seconds: seconds));
    final result = await rpc('ext.foto.frames', {'isolateId': isolate, 'action': 'stop'});
    result.addAll({'scenario': scenario, 'operatorSourceSha': sha, 'startedUtc': started, 'seconds': seconds});
    await File(output).writeAsString('${const JsonEncoder.withIndent('  ').convert(result)}\n');
    if (result['sourceSha'] != sha) {
      throw StateError('Compiled source provenance differs; set FOTO_PROFILE_SOURCE_SHA when building');
    }
    if (result['frames'] == 0 || result['droppedSamples'] != 0) {
      throw StateError('Empty/truncated capture; evidence is invalid');
    }
    stdout.writeln(
      'Recorded ${result['frames']} frames in $output; device identity, actual refresh rate and acceptance still require review.',
    );
  } finally {
    await socket.close();
  }
}
