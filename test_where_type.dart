import 'dart:convert';
import 'dart:io';

void main() {
  final text = File('test_json.txt').readAsStringSync();
  try {
    final parsed = jsonDecode(text);
    if (parsed.containsKey('neighbors') && parsed['neighbors'] is List) {
       final list = parsed['neighbors'] as List;
       final filtered = list.whereType<Map<String, dynamic>>().toList();
       print("Filtered length: " + filtered.length.toString());
    }
  } catch (e) {
    print("Error: " + e.toString());
  }
}
