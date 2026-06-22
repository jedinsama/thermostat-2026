import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

// The main() function is the entry point, just like the _ready() function in a main script.
void main() {
  runApp(const ThermostatApp());
}

// StatelessWidget means this root configuration doesn't change dynamically.
class ThermostatApp extends StatelessWidget {
  const ThermostatApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MaterialApp provides the foundational styling and navigation structure for the whole app.
    return MaterialApp(
      title: 'Thermostat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true, // Enables the latest Google Material Design visuals
      ),
      // This tells the app to load the LoginScreen immediately upon launching.
      home: const LoginScreen(), 
      // Hides the "DEBUG" banner in the top right corner for a cleaner presentation.
      debugShowCheckedModeBanner: false, 
    );
  }
}