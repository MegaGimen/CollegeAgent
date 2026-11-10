import 'package:url_launcher/url_launcher.dart';

void triggerBrowserDownload(String url, String fileName) {
  try {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}
