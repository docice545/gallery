import 'package:flutter_test/flutter_test.dart';
import 'package:openapi/api.dart';

void main() {
  const id = '00000000-0000-4000-8000-000000000001';
  const group = '00000000-0000-4000-8000-000000000002';

  test('accepts legacy upload responses without duplicateId', () {
    final response = AssetMediaResponseDto.fromJson({'id': id, 'status': 'created'});
    expect(response?.id, id);
    expect(response?.toJson().containsKey('duplicateId'), isFalse);
  });

  test('accepts an explicit null duplicate group', () {
    final response = AssetMediaResponseDto.fromJson({'id': id, 'status': 'duplicate', 'duplicateId': null});
    expect(response?.id, id);
    expect(response?.toJson(), containsPair('duplicateId', null));
  });

  test('keeps the asset ID distinct from its verified duplicate group', () {
    final response = AssetMediaResponseDto.fromJson({'id': id, 'status': 'created', 'duplicateId': group});
    expect(response?.id, id);
    expect(response?.toJson()['duplicateId'], group);
  });
}
