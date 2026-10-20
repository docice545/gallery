/// Save choices supported by the editor.
enum EditSaveMode { copy, replace, cancel }

/// The mobile editor never overwrites a remote, external-library, or Motion Photo original.
class EditSavePolicy {
  const EditSavePolicy._();

  static bool canReplace({required bool isExternalLibrary, required bool isMotionPhoto}) => false;
}
