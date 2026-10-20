import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/edit_save_policy.dart';

void main() {
  test('replace is disabled until an atomic backup and library refresh path exists', () {
    expect(EditSavePolicy.canReplace(isExternalLibrary: false, isMotionPhoto: false), isFalse);
    expect(EditSavePolicy.canReplace(isExternalLibrary: true, isMotionPhoto: false), isFalse);
    expect(EditSavePolicy.canReplace(isExternalLibrary: false, isMotionPhoto: true), isFalse);
  });
}
