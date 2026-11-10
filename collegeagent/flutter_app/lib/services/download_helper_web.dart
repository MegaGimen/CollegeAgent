import 'dart:html' as html;

void triggerBrowserDownload(String url, String fileName) {
  try {
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..style.display = 'none';
    html.document.body?.children.add(anchor);
    anchor.click();
    anchor.remove();
  } catch (_) {
    try {
      html.window.open(url, '_blank');
    } catch (_) {}
  }
}
