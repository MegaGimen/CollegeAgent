import 'dart:convert';

void main() {
  String text = '''{"nodeId":"1555334_undefined_module-3","title":"Module 3","path":"canvas_1555334_Module-3.md","content":" 1|# Module 3\n 2|\n 3|**URL**: https://bcourses.berkeley.edu/courses/1555334/pages/module-3\n 4|\n 5|ModuleModule [1](https://bcourses.berkeley.edu/courses/1555334/pages/module-1 \"Module 1\")     Module [2](https://bcourses.berkeley.edu/courses/1555334/pages/module-2-3 \"Module 2\")     Module 3     Module [4](https://bcourses.berkeley.edu/courses/1555334/pages/module-4 \"Module 4\")\n 6|\n 7|Module 3Intervention\n 8|--------------------\n 9|\n10|This module will focus on ways you can intervene in different ... (truncated)","totalLines":20,"outboundLinks":[{"nodeId":"url_45985e60320700dd","url":"https://bcourses.berkeley.edu/courses/1555334/pages/module-1","title":"1"}],"neighbors":[{"title":"1","sourceUrl":"https://bcourses.berkeley.edu/courses/1555334/pages/module-1","content":"1","totalLines":2}]}''';

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
