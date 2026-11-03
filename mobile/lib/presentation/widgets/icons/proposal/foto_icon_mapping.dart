// Proposed mapping, not production button replacement or action enablement.
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';

import 'foto_icon_paths.dart';

const fotoEditorModeIcons = <EditorMode, FotoIconKind>{
  EditorMode.crop: FotoIconKind.crop,
  EditorMode.adjustments: FotoIconKind.adjustments,
  EditorMode.filters: FotoIconKind.filters,
  EditorMode.draw: FotoIconKind.draw,
  EditorMode.text: FotoIconKind.text,
  EditorMode.shapes: FotoIconKind.shapes,
  EditorMode.stickers: FotoIconKind.sticker,
  EditorMode.magicEraser: FotoIconKind.magicEraser,
};

const fotoAnnotationToolIcons = <AnnotationTool, FotoIconKind>{
  AnnotationTool.pen: FotoIconKind.pen,
  AnnotationTool.brush: FotoIconKind.brush,
  AnnotationTool.highlighter: FotoIconKind.highlighter,
  AnnotationTool.eraser: FotoIconKind.eraser,
  AnnotationTool.text: FotoIconKind.text,
  AnnotationTool.sticker: FotoIconKind.sticker,
  AnnotationTool.move: FotoIconKind.move,
  AnnotationTool.arrow: FotoIconKind.arrow,
  AnnotationTool.rectangle: FotoIconKind.rectangle,
  AnnotationTool.ellipse: FotoIconKind.ellipse,
};

const fotoViewerActionIcons = <ActionButtonType, FotoIconKind>{
  ActionButtonType.openInfo: FotoIconKind.info,
  ActionButtonType.likeActivity: FotoIconKind.favorite,
  ActionButtonType.share: FotoIconKind.share,
  ActionButtonType.shareLink: FotoIconKind.link,
  ActionButtonType.cast: FotoIconKind.cast,
  ActionButtonType.setAlbumCover: FotoIconKind.cover,
  ActionButtonType.similarPhotos: FotoIconKind.similar,
  ActionButtonType.setProfilePicture: FotoIconKind.profile,
  ActionButtonType.viewInTimeline: FotoIconKind.timeline,
  ActionButtonType.slideshow: FotoIconKind.slideshow,
  ActionButtonType.download: FotoIconKind.download,
  ActionButtonType.upload: FotoIconKind.upload,
  ActionButtonType.openInBrowser: FotoIconKind.browser,
  ActionButtonType.unstack: FotoIconKind.unstack,
  ActionButtonType.manageStack: FotoIconKind.stack,
  ActionButtonType.archive: FotoIconKind.archive,
  ActionButtonType.unarchive: FotoIconKind.unarchive,
  ActionButtonType.moveToLockFolder: FotoIconKind.lock,
  ActionButtonType.removeFromLockFolder: FotoIconKind.unlock,
  ActionButtonType.removeFromAlbum: FotoIconKind.removeAlbum,
  ActionButtonType.restoreTrash: FotoIconKind.restore,
  ActionButtonType.deleteLocal: FotoIconKind.deviceTrash,
  ActionButtonType.deleteEverywhere: FotoIconKind.trash,
  ActionButtonType.delete: FotoIconKind.trash,
  ActionButtonType.advancedInfo: FotoIconKind.debug,
};
