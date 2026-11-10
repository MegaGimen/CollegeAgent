import 'dart:core';

void main() {
  final raw = '[49,28-42]';
  final numMatch = RegExp(r'\[(\d+)').firstMatch(raw);
  print('parsedSourceId: ${numMatch?.group(1)}');
}
