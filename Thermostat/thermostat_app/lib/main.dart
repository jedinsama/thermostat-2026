import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart'; // We are back to routing straight here

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  SharedPreferences prefs = await SharedPreferences.getInstance();
  bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

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
          theme: ThemeData(
            brightness: Brightness.light,
            primarySwatch: Colors.blue,
            useMaterial3: true,
            scaffoldBackgroundColor: Colors.white, 
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.blueGrey,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF121212), 
          ),
          themeMode: currentMode,
          // Route straight to the Dashboard if they are logged in
          home: isLoggedIn ? const DashboardScreen() : const LoginScreen(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}