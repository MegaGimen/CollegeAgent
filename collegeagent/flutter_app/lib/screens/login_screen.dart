import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _serverCtrl.text = auth.serverUrl;
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0C132C) : Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy,
                size: 72,
                color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF0C132C),
              ),
              const SizedBox(height: 16),
              Text(
                'ICE Agent',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Ideal College Education Agent',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your username to start chatting',
                style: TextStyle(
                  color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _usernameCtrl,
                autofocus: true,
                style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _login(),
                decoration: InputDecoration(
                  labelText: 'Username',
                  labelStyle: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  ),
                  prefixIcon: Icon(
                    Icons.person,
                    color: isDark ? const Color(0xFF64B5F6) : Colors.grey.shade600,
                  ),
                  filled: isDark,
                  fillColor: isDark ? const Color(0xFF01385F) : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: auth.loading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? const Color(0xFF01385F) : const Color(0xFF0C132C),
                    foregroundColor: Colors.white,
                    side: isDark ? const BorderSide(color: Color(0xFF1E4E79)) : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: auth.loading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Login', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 16),
                Text(
                  auth.error!,
                  style: TextStyle(color: isDark ? Colors.redAccent : Colors.red),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                style: TextButton.styleFrom(
                  foregroundColor: isDark ? const Color(0xFF64B5F6) : const Color(0xFF0C132C),
                ),
                child: Text(_showAdvanced ? 'Hide settings' : 'Server settings'),
              ),
              if (_showAdvanced) ...[
                TextField(
                  controller: _serverCtrl,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    labelStyle: TextStyle(
                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    ),
                    prefixIcon: Icon(
                      Icons.link,
                      color: isDark ? const Color(0xFF64B5F6) : Colors.grey.shade600,
                    ),
                    filled: isDark,
                    fillColor: isDark ? const Color(0xFF01385F) : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _login() {
    final auth = context.read<AuthProvider>();
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty) return;
    auth.setServerUrl(_serverCtrl.text.trim());
    auth.login(username);
  }
}
