import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Short random id used for projects, clips and layers.
String newId() => _uuid.v4().replaceAll('-', '').substring(0, 16);
