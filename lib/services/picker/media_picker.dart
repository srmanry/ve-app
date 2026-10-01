import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/repositories/media_repository.dart';

enum PickSource { gallery, files }

const _imageExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'bmp', 'gif'};

/// Whether a picked file name looks like a photo.
bool isImageFileName(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 && _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Wraps the system pickers. Both use OS-provided UIs (Android Photo Picker
/// / SAF, iOS PHPicker / document picker) that grant access to the chosen
/// files only - no storage or photo-library permission is requested.
class MediaPicker {
  MediaPicker({ImagePicker? imagePicker}) : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  Future<List<PickedMedia>> pickVideos(PickSource source, {bool multiple = true}) async {
    if (source == PickSource.gallery) {
      final files = multiple
          ? await _imagePicker.pickMultiVideo()
          : [?await _imagePicker.pickVideo(source: ImageSource.gallery)];
      return [
        for (final f in files) PickedMedia(name: f.name, path: f.path, deleteAfterImport: true),
      ];
    }
    return _pickFiles(FileType.video, multiple: multiple);
  }

  /// Picks several photos at once (gallery multi-select or files).
  Future<List<PickedMedia>> pickImages(PickSource source) async {
    if (source == PickSource.gallery) {
      final files = await _imagePicker.pickMultiImage();
      return [
        for (final f in files) PickedMedia(name: f.name, path: f.path, deleteAfterImport: true),
      ];
    }
    return _pickFiles(FileType.image, multiple: true);
  }

  /// One photo from the system camera app (documents, signatures).
  Future<List<PickedMedia>> takePhoto() async {
    final f = await _imagePicker.pickImage(source: ImageSource.camera, imageQuality: 95);
    return [if (f != null) PickedMedia(name: f.name, path: f.path, deleteAfterImport: true)];
  }

  /// Videos and photos from the file browser (mixed selection).
  Future<List<PickedMedia>> pickVisualFiles() => _pickFiles(FileType.media, multiple: true);

  Future<List<PickedMedia>> pickAudio({bool multiple = false}) =>
      _pickFiles(FileType.audio, multiple: multiple);

  Future<List<PickedMedia>> _pickFiles(FileType type, {required bool multiple}) async {
    final files = multiple
        ? await FilePicker.pickFiles(type: type)
        : [?await FilePicker.pickFile(type: type)];
    final tempRoots = [
      (await getTemporaryDirectory()).path,
      (await getApplicationCacheDirectory()).path,
    ];
    return [
      for (final f in files)
        PickedMedia(
          name: f.name,
          path: f.path,
          openRead: f.path == null ? () => f.readAsByteStream() : null,
          // Only delete copies the picker placed in our own temp/cache dirs.
          deleteAfterImport: f.path != null && tempRoots.any((root) => f.path!.startsWith(root)),
        ),
    ];
  }
}
