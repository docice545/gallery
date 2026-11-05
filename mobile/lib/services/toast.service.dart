import 'dart:async';

import 'package:immich_ui/immich_ui.dart';

class ToastOption {
  final Duration? timeout;
  final FutureOr<void> Function()? onUndo;
  final String? undoLabel;
  final bool neutral;

  const ToastOption({this.timeout, this.onUndo, this.undoLabel, this.neutral = false});
}

class ToastService {
  const ToastService();

  FutureOr<void> success(String message, {ToastOption? toast}) {
    if (toast?.neutral == true) {
      snackbar.neutral(message, duration: toast?.timeout, action: toast?.action);
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
