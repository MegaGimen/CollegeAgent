import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

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
    final completer = Completer<List<PickedFileResult>>();
    final input = html.FileUploadInputElement();
    input.multiple = allowMultiple;
    if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
      input.accept = allowedExtensions
          .map((e) => e.startsWith('.') ? e : '.$e')
          .join(',');
    }

    input.onChange.listen((e) async {
      final files = input.files;
      if (files == null || files.isEmpty) {
        if (!completer.isCompleted) completer.complete([]);
        return;
      }

      final results = <PickedFileResult>[];
      for (final file in files) {
        final readerCompleter = Completer<Uint8List?>();
        final reader = html.FileReader();
        reader.onLoadEnd.listen((_) {
          final res = reader.result;
          Uint8List? bytes;
          if (res is Uint8List) {
            bytes = res;
          } else if (res is ByteBuffer) {
            bytes = res.asUint8List();
          } else if (res is List<int>) {
            bytes = Uint8List.fromList(res);
          }
          if (!readerCompleter.isCompleted) readerCompleter.complete(bytes);
        });
        reader.onError.listen((_) {
          if (!readerCompleter.isCompleted) readerCompleter.complete(null);
        });
        reader.readAsArrayBuffer(file);
        final fileBytes = await readerCompleter.future;
        if (fileBytes != null) {
          results.add(PickedFileResult(name: file.name, bytes: fileBytes));
        }
      }
      if (!completer.isCompleted) completer.complete(results);
    });

    input.click();
    return completer.future;
  }
}
