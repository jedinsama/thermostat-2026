import 'package:flutter/material.dart';
import 'dashboard_screen.dart'; // <-- IMPORT ADDED HERE

// Upgraded to StatefulWidget to handle dynamic UI changes (Dropdown & Date Picker)
class ProfileCreationScreen extends StatefulWidget {
  const ProfileCreationScreen({super.key});

  @override
  State<ProfileCreationScreen> createState() => _ProfileCreationScreenState();
}

class _ProfileCreationScreenState extends State<ProfileCreationScreen> {
  // Controllers and state variables to store user input
  final TextEditingController _birthdayController = TextEditingController();
  String? _selectedCondition;

  // The list of items for our dropdown menu
  final List<String> _medicalConditions = [
    'None',
    'Hypertension',
    'Diabetes',
    'Asthma',
    'Cardiovascular Disease',
    'Other'
  ];

  // Function to pop up the calendar for birthday selection
  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2000, 1, 1), // Default date when calendar opens
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        // Formats the date to YYYY-MM-DD
        _birthdayController.text = "${picked.toLocal()}".split(' ')[0];
      });
    }
  }

  // Function to show the informational popup about BMI
  void _showBmiInfoDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("What is BMI?"),
          content: const Text(
            "BMI (Body Mass Index) is a measurement that uses your height and weight to work out if your weight is healthy.\n\n"
            "How to calculate it manually:\n"
            "BMI = Weight (kg) ÷ [Height (m)]²\n\n"
            "For example, if you weigh 70kg and are 1.75m tall:\n"
            "70 ÷ (1.75 × 1.75) = 22.9",
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Closes the dialog
              },
              child: const Text("Got it"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Complete Your Profile"),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Personalized Health Data",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "This helps us accurately calculate your dynamic heatstroke risk score.",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),

            // 1. Full Name Input
            const TextField(
              decoration: InputDecoration(
                labelText: "Full Name",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // 2. Birthday Input (Tapping it opens the Date Picker)
            TextField(
              controller: _birthdayController,
              readOnly: true, // Prevents typing, forces the use of the date picker
              onTap: () => _selectDate(context),
              decoration: const InputDecoration(
                labelText: "Birthday (YYYY-MM-DD)",
                border: OutlineInputBorder(),
                suffixIcon: Icon(Icons.calendar_today),
              ),
            ),
            const SizedBox(height: 16),

            // 3. Medical Condition Dropdown
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: "Primary Medical Condition",
                border: OutlineInputBorder(),
              ),
              value: _selectedCondition,
              items: _medicalConditions.map((String condition) {
                return DropdownMenuItem<String>(
                  value: condition,
                  child: Text(condition),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  _selectedCondition = newValue;
                });
              },
            ),
            const SizedBox(height: 16),

            // 4. BMI Input with Help Button
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: TextField(
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: "BMI",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // The Question Mark Button
                IconButton(
                  icon: const Icon(Icons.help_outline, color: Colors.blue, size: 28),
                  onPressed: _showBmiInfoDialog,
                  tooltip: "How to get your BMI",
                ),
              ],
            ),
            const SizedBox(height: 32),

            // 5. Routed Register Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  // pushReplacement prevents the user from swiping back to the profile creation screen
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => const DashboardScreen()),
                  );
                },
                child: const Text("REGISTER"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}