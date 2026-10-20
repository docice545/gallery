import 'dart:ui' show Offset;

import 'package:immich_mobile/domain/models/annotation.model.dart';

/// Undoable annotation document used by the editor surface.
///
/// Each mutation stores an immutable snapshot. This keeps undo/redo predictable
/// when a gesture is followed by a move or a text edit and also ensures that
/// the original asset is never modified while editing.
class AnnotationEditor {
  List<AnnotationElement> _elements = const [];
  final List<List<AnnotationElement>> _undo = [];
  final List<List<AnnotationElement>> _redo = [];

  List<AnnotationElement> get elements => List.unmodifiable(_elements);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void add(AnnotationElement element) {
    _record();
    _elements = [..._elements, element];
  }

  bool remove(String id) {
    final index = _elements.indexWhere((element) => element.id == id);
    if (index < 0) {
      return false;
    }
    _record();
    _elements = [..._elements]..removeAt(index);
    return true;
  }

  bool removeMany(Iterable<String> ids) {
    final removals = ids.toSet();
    if (removals.isEmpty || !_elements.any((element) => removals.contains(element.id))) {
      return false;
    }
    _record();
    _elements = _elements.where((element) => !removals.contains(element.id)).toList(growable: false);
    return true;
  }

  bool move(String id, Offset delta) {
    final index = _elements.indexWhere((element) => element.id == id);
    if (index < 0) {
      return false;
    }
    _record();
    final updated = [..._elements];
    updated[index] = updated[index].translated(delta);
    _elements = updated;
    return true;
  }

  bool update(AnnotationElement element) {
    final index = _elements.indexWhere((current) => current.id == element.id);
    if (index < 0) {
      return false;
    }
    _record();
    final updated = [..._elements]..[index] = element;
    _elements = updated;
    return true;
  }

  bool undo() {
    if (!canUndo) {
      return false;
    }
    _redo.add(_elements);
    _elements = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (!canRedo) {
      return false;
    }
    _undo.add(_elements);
    _elements = _redo.removeLast();
    return true;
  }

  void clear() {
    if (_elements.isEmpty) {
      return;
    }
    _record();
    _elements = const [];
  }

  void _record() {
    _undo.add(_elements);
    _redo.clear();
  }
}
