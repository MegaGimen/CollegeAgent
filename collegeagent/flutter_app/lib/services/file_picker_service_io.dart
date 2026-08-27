import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

class PickedFileResult {
  final String name;
  final Uint8List bytes;
  PickedFileResult({required this.name, required this.bytes});
}

class AppFilePicker {
  static Future<List<PickedFileResult>> pickFiles({
    List<String>? allowedExtensions,
    bool allowMultiple = true,
  }) async {
    final cleanExtensions = allowedExtensions
        ?.map((e) => e.startsWith('.') ? e.substring(1) : e)
        .toList();

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
      type: cleanExtensions != null ? FileType.custom : FileType.any,
      allowedExtensions: cleanExtensions,
      withData: true,
    );

    if (result == null || result.files.isEmpty) return [];

    final results = <PickedFileResult>[];
    for (final file in result.files) {
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes != null) {
        results.add(PickedFileResult(name: file.name, bytes: bytes));
      }
    }
    return results;
  }
}
