import 'package:flutter/material.dart';
import 'register_screen.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Scaffold is the base UI canvas for this specific screen.
    return Scaffold(
      body: Padding(
        // Padding adds empty space around the edges so the UI isn't touching the screen borders.
        padding: const EdgeInsets.all(24.0),
        // Column stacks all its 'children' vertically, exactly like a VBoxContainer.
        child: Column(
          // Centers all the children vertically on the screen.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // A placeholder icon for your app's logo.
            const Icon(Icons.thermostat, size: 80, color: Colors.blue),
            const SizedBox(height: 20), // SizedBox is used to create empty vertical space.
            
            const Text(
              "Welcome to Thermostat",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            
            // Text input for the user's email.
            const TextField(
              decoration: InputDecoration(
                labelText: "Email",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            
            // Text input for the password. obscureText hides the characters (bullet points).
            const TextField(
              obscureText: true, 
              decoration: InputDecoration(
                labelText: "Password",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            
            // SizedBox forces the button inside it to take up the full width of the screen.
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  // TODO: Later, your database authentication logic will go here.
                  // If successful, you will route them to the Main Dashboard.
                },
                child: const Text("LOGIN"),
              ),
            ),
            
            // A clickable text link to jump to the Register screen.
            TextButton(
              onPressed: () {
                // Navigator handles changing screens (scenes).
                // .push() layers the new screen on top, allowing the user to press 'back'.
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const RegisterScreen()),
                );
              },
              child: const Text("Don't have an account? Register here"),
            )
          ],
        ),
      ),
    );
  }
}