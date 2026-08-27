import 'dart:convert';
void main() {
  final result = '{"a": 1}';
  final parsed = jsonDecode(result);
  print(parsed is Map<String, dynamic>);
}
