import 'package:gal/gal.dart';

import '../errors/app_exception.dart';

/// The only runtime permission the app asks for: *adding* a finished export
/// to the photo gallery, and only at the moment the user taps "Save".
///
/// Importing uses the system photo/document pickers, which grant access to
/// the chosen files without any permission prompt on modern Android/iOS.
class GalleryPermission {
  const GalleryPermission();

  Future<void> ensureCanSave() async {
    if (await Gal.hasAccess()) return;
    final granted = await Gal.requestAccess();
    if (!granted) throw AppException.permissionDenied('save to your gallery');
  }
}
