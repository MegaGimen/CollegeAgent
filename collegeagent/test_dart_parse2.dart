import 'dart:core';

void main() {
  final regex = RegExp(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');
  final text = "8/26–9/4，通过官网预约 1v1 [49, 28-42] |";
  final matches = regex.allMatches(text);
  for (final match in matches) {
    print('Match: ${match.group(0)}');
    final numMatch = RegExp(r'\[(\d+)').firstMatch(match.group(0)!);
    print('Parsed ID: ${numMatch?.group(1)}');
  }
}
