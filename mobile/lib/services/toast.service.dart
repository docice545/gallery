import 'dart:async';

import 'package:immich_ui/immich_ui.dart';

class ToastOption {
  final Duration? timeout;
  final bool compact;
  final String? undoLabel;
  final FutureOr<void> Function()? onUndo;

  const ToastOption({this.timeout, this.onUndo, this.compact = false, this.undoLabel});
}

class ToastService {
  const ToastService();

  FutureOr<void> success(String message, {ToastOption? toast}) {
    if (toast?.compact == true) {
      snackbar.compact(message, duration: toast?.timeout, action: toast?.action);
    } else {
      snackbar.success(message, duration: toast?.timeout, action: toast?.action);
    }
  }

  FutureOr<void> error(String message, {ToastOption? toast}) {
    snackbar.error(message, duration: toast?.timeout, action: toast?.action);
  }
}

extension on ToastOption {
  SnackbarAction? get action {
    final onUndo = this.onUndo;
    if (onUndo == null) {
      return null;
    }

    return SnackbarAction(label: undoLabel, onPressed: onUndo);
  }
}
