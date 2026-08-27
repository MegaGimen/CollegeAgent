/// Cross-platform LocalDb entry point.
///
/// - On mobile / desktop (dart:io available) → uses sqflite via [local_db_io.dart]
/// - On web (dart:html or dart:js_interop)    → uses shared_preferences via [local_db_html.dart]
///
/// Both implementations expose the same `LocalDb` class with identical APIs,
/// so the rest of the app can `import 'services/local_db.dart'` unchanged.
export 'local_db_io.dart' if (dart.library.js_interop) 'local_db_html.dart' if (dart.library.html) 'local_db_html.dart';

