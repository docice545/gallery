class PermanentDeletionResult {
  final String id;
  final String state;
  final String? code;
  final String? scope;
  final String? batchId;
  const PermanentDeletionResult({required this.id, required this.state, this.code, this.scope, this.batchId});
  bool get complete => state == 'complete';
}

class LocalDeletionResult {
  final List<String> deletedIds;
  final List<String> remainingIds;
  const LocalDeletionResult({required this.deletedIds, required this.remainingIds});
}

class ManagedDeletionStatus {
  final bool enabled;
  final bool prepared;
  final bool canPrepare;
  const ManagedDeletionStatus({required this.enabled, required this.prepared, required this.canPrepare});
}
