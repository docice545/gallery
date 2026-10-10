class PermanentDeletionResult {
  final String id;
  final String state;
  final String? code;
  const PermanentDeletionResult({required this.id, required this.state, this.code});
  bool get complete => state == 'complete';
}

class LocalDeletionResult {
  final List<String> deletedIds;
  final List<String> remainingIds;
  const LocalDeletionResult({required this.deletedIds, required this.remainingIds});
}
