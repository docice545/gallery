import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_photo.widget.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

void main() {
  late MemoryImage image;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final bitmap = await createTestImage(width: 256, height: 256);
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    image = MemoryImage(bytes!.buffer.asUint8List());
    bitmap.dispose();
  });

  testWidgets('double tap zoom pauses paging; reset restores paging and tap navigation', (tester) async {
    final interactions = <bool>[];
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryPhoto(
            imageProvider: image,
            isCurrent: true,
            onInteractionChanged: interactions.add,
            onNext: () => next++,
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(MemoryPhoto))));
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
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(next, 1);
  });

  testWidgets('two pointers pause paging even before scale changes', (tester) async {
    final interactions = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryPhoto(imageProvider: image, isCurrent: true, onInteractionChanged: interactions.add),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(MemoryPhoto))));
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

  testWidgets('zoomed drag pans the photo; contained drag changes the page', (tester) async {
    final pagingLocked = ValueNotifier(false);
    final pages = PageController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: pagingLocked,
            builder: (context, locked, _) => PageView(
              controller: pages,
              physics: locked ? const NeverScrollableScrollPhysics() : const AlwaysScrollableScrollPhysics(),
              children: [
                MemoryPhoto(
                  imageProvider: image,
                  isCurrent: true,
                  onInteractionChanged: (value) => pagingLocked.value = value,
                ),
                const ColoredBox(color: Colors.blue),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(MemoryPhoto))));
    await tester.pumpAndSettle();
    final photo = tester.widget<PhotoView>(find.byType(PhotoView));
    final controller = photo.controller!;
    controller.updateMultiple(scale: controller.initialScale! * 2, position: Offset.zero);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PhotoView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(controller.position.dx, lessThan(0));
    controller.updateMultiple(scale: controller.initialScale, position: Offset.zero);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PhotoView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    await tester.pumpWidget(const SizedBox());
    pages.dispose();
    pagingLocked.dispose();
  });
}
