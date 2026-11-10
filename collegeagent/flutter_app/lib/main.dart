import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_service.dart';
import 'services/local_db.dart';
import 'providers/auth_provider.dart';
import 'providers/session_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/theme_provider.dart';
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
          create: (_) => ThemeProvider(),
        ),
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
      child: Builder(
        builder: (context) {
          final themeProv = context.watch<ThemeProvider>();
          return MaterialApp(
            title: 'ICE Agent',
            debugShowCheckedModeBanner: false,
            scrollBehavior: const MaterialScrollBehavior().copyWith(
              dragDevices: {
                PointerDeviceKind.mouse,
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.unknown,
                PointerDeviceKind.trackpad,
              },
            ),
            themeMode: themeProv.themeMode,
        theme: ThemeData(
          brightness: Brightness.light,
          fontFamily: 'Times New Roman',
          scaffoldBackgroundColor: const Color(0xFFF8F9FA),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0C132C),
            brightness: Brightness.light,
          ),
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: Color(0xFF01385F),
            selectionColor: Color(0x6601385F),
            selectionHandleColor: Color(0xFF01385F),
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            elevation: 0,
          ),
        ),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Times New Roman',
          scaffoldBackgroundColor: const Color(0xFF0C132C),
          canvasColor: const Color(0xFF0C132C),
          cardColor: const Color(0xFF01385F),
          dividerColor: const Color(0xFF1E3A5F),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF01385F),
            secondary: Color(0xFF2196F3),
            surface: Color(0xFF0C132C),
            onSurface: Colors.white,
          ),
          textSelectionTheme: TextSelectionThemeData(
            cursorColor: const Color(0xFF38BDF8),
            selectionColor: const Color(0xFF38BDF8).withValues(alpha: 0.35),
            selectionHandleColor: const Color(0xFF38BDF8),
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0C132C),
            foregroundColor: Colors.white,
            centerTitle: false,
            elevation: 0,
          ),
        ),
        home: const _AuthGate(),
          );
        },
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
