import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_photo.widget.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

void main() {
  final image = MemoryImage(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
  ));

  testWidgets('double tap zoom pauses paging; reset restores paging and tap navigation', (tester) async {
    final interactions = <bool>[];
    var next = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MemoryPhoto(
      imageProvider: image,
      isCurrent: true,
      onInteractionChanged: interactions.add,
      onNext: () => next++,
    ))));
    await tester.pumpAndSettle();
    final photo = tester.widget<PhotoView>(find.byType(PhotoView));
    final position = tester.getCenter(find.byType(PhotoView));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position);
    await tester.pumpAndSettle();
    expect(interactions.last, isTrue);
    expect(next, 0);
    photo.controller!.updateMultiple(scale: photo.controller!.initialScale, position: Offset.zero);
    await tester.pumpAndSettle();
    expect(interactions.last, isFalse);
    await tester.tapAt(position + const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(next, 1);
  });

  testWidgets('two pointers pause paging even before scale changes', (tester) async {
    final interactions = <bool>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MemoryPhoto(
      imageProvider: image,
      isCurrent: true,
      onInteractionChanged: interactions.add,
    ))));
    await tester.pumpAndSettle();
    final first = await tester.startGesture(const Offset(200, 200), pointer: 1);
    final second = await tester.startGesture(const Offset(300, 200), pointer: 2);
    await tester.pump();
    expect(interactions.last, isTrue);
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(interactions.last, isFalse);
  });
}
