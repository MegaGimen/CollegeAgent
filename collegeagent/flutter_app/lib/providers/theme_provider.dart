import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const _key = 'app_theme_mode';
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved == 'dark') {
        _themeMode = ThemeMode.dark;
      } else if (saved == 'light') {
        _themeMode = ThemeMode.light;
      } else {
        _themeMode = ThemeMode.system;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mode == ThemeMode.dark) {
        await prefs.setString(_key, 'dark');
      } else if (mode == ThemeMode.light) {
        await prefs.setString(_key, 'light');
      } else {
        await prefs.setString(_key, 'system');
      }
    } catch (_) {}
  }

  void toggleTheme(BuildContext context) {
    final currentBrightness = Theme.of(context).brightness;
    if (_themeMode == ThemeMode.system) {
      if (currentBrightness == Brightness.dark) {
        setThemeMode(ThemeMode.light);
      } else {
        setThemeMode(ThemeMode.dark);
      }
    } else if (_themeMode == ThemeMode.dark) {
      setThemeMode(ThemeMode.light);
    } else {
      setThemeMode(ThemeMode.dark);
    }
  }
}
