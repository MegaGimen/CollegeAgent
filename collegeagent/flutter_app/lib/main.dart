import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_service.dart';
import 'services/local_db.dart';
import 'providers/auth_provider.dart';
import 'providers/session_provider.dart';
import 'providers/chat_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CollegeAgentApp());
}

class CollegeAgentApp extends StatelessWidget {
  const CollegeAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = ApiService();
    final localDb = LocalDb();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(api: api, localDb: localDb)
            ..restoreSession(),
        ),
        ChangeNotifierProvider(
          create: (_) => SessionProvider(api: api, localDb: localDb),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(api: api, localDb: localDb),
        ),
      ],
      child: MaterialApp(
        title: 'CollegeAgent Chat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6C63FF),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            elevation: 0,
          ),
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (auth.isLoggedIn) {
      return const HomeScreen();
    }
    return const LoginScreen();
  }
}
