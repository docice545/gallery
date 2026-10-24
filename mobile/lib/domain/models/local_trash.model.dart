/// The observed result of a trash-only device operation.
///
/// A server ACK or an accepted Android request is not evidence that the file
/// reached the system trash. Only these two observed states complete the intent.
class LocalTrashResult {
  final String code;
  final String? message;

  const LocalTrashResult({required this.code, this.message});

  bool get isTrashed => code == 'trashed' || code == 'alreadyTrashed';
}
