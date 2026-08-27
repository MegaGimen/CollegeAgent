import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/local_db.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService api;
  final LocalDb localDb;

  UserModel? _user;
  bool _loading = false;
  String? _error;
  String _serverUrl = 'https://llinker.com/collegeagent-api';

  AuthProvider({required this.api, required this.localDb});

  UserModel? get user => _user;
  bool get loading => _loading;
  String? get error => _error;
  String get serverUrl => _serverUrl;
  bool get isLoggedIn => _user != null;

  void setServerUrl(String url) {
    _serverUrl = url;
    api.baseUrl = url;
    notifyListeners();
  }

  Future<void> login(String username) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      api.baseUrl = _serverUrl;
      _user = await api.login(username);

      // Persist login
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'user',
        jsonEncode(_user!.toJson()),
      );
      await prefs.setString('serverUrl', _serverUrl);

      _loading = false;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('user');
      final savedUrl = prefs.getString('serverUrl');
      if (savedUrl != null) {
        _serverUrl = savedUrl;
        api.baseUrl = savedUrl;
      }
      if (userJson != null) {
        _user = UserModel.fromJson(
          jsonDecode(userJson) as Map<String, dynamic>,
        );
        notifyListeners();
      }
    } catch (_) {
      // Ignore restore errors
    }
  }

  void logout() {
    _user = null;
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('user');
    });
    notifyListeners();
  }
}
