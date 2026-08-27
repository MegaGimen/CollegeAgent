import 'dart:convert';
import 'dart:io';

void main() {
  final text = File('test_json.txt').readAsStringSync();
  try {
    final parsed = jsonDecode(text);
    print("Parsed successfully: \${parsed['title']}");
    if (parsed.containsKey('neighbors') && parsed['neighbors'] is List) {
       print("Neighbors found: \${parsed['neighbors'].length}");
    } else {
       print("No neighbors found");
    }
  } catch (e) {
    print("Parse failed: \$e");
  }
}
