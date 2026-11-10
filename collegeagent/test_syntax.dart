import 'dart:core';

void main() {
  final raw = '''- **Berkeley Connect in PHILOS 首次小组合【今天】**:mentor Jennifer Marsh 通知首次小组会就在今天周三,两场可选:5-6pm 在 Dwinelle 262,或 6-7pm 在 Dwinelle 134。Berkeley Connect 是 Pass/Fail 只需考勤;若不能到需提前告知她以免被记缺勤 [11, 19-27]''';
  final regex = RegExp(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');
  final matches = regex.allMatches(raw);
  print('Matches: ${matches.length}');
  for (final m in matches) {
    print(m.group(0));
  }
}
