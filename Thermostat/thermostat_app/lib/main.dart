import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Adjust these imports based on where your files actually live in your project
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';

// This controls the global Light/Night mode toggle
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

void main() async {
  // 1. Ensures Flutter's engine is fully awake before reading device memory
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Checks the phone's memory to see if the user is already logged in
  SharedPreferences prefs = await SharedPreferences.getInstance();
  bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

  // 3. Starts the app and hands it the login status
  runApp(ThermostatApp(isLoggedIn: isLoggedIn));
}

class ThermostatApp extends StatelessWidget {
  final bool isLoggedIn;

  const ThermostatApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          title: 'Thermostat',

          // --- LIGHT THEME (Matches your sleek new white UI) ---
          theme: ThemeData(
            brightness: Brightness.light,
            primarySwatch: Colors.blue,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFF4F6F8),
          ),

          // --- DARK THEME ---
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.blueGrey,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF121212),
          ),

          themeMode: currentMode,

          // --- THE ROUTER ---
          // Sends returning users straight to the passive scanner dashboard,
          // and new users to the login screen.
          home: isLoggedIn ? const DashboardScreen() : const LoginScreen(),

          debugShowCheckedModeBanner: false, // Hides the red "DEBUG" banner
        );
      },
    );
  }
}
