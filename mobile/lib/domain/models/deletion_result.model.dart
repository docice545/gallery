class PermanentDeletionResult {
  final String id;
  final String state;
  final String? code;
  final String? scope;
  final String? batchId;
  final bool serverAccepted;
  const PermanentDeletionResult({
    required this.id,
    required this.state,
    this.code,
    this.scope,
    this.batchId,
    this.serverAccepted = false,
  });
  bool get complete => state == 'complete';

  /// Only a durable server acknowledgement (or physical completion) proves
  /// irreversibility. A queued legacy batch is not an accepted deletion.
  bool get accepted => serverAccepted || complete;
}

class PermanentDeletionBatchStatus {
  final String id;
  final String state;
  final int total;
  final int processed;
  final int complete;
  final int failed;
  final int pending;
  final bool cancelRequested;

  const PermanentDeletionBatchStatus({
    required this.id,
    required this.state,
    required this.total,
    required this.processed,
    required this.complete,
    required this.failed,
    required this.pending,
    required this.cancelRequested,
  });

  bool get cancelled => state == 'cancelled' || cancelRequested;
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
