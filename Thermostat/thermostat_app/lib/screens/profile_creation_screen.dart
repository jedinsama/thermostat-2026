import 'package:flutter/material.dart';
import 'permissions_screen.dart';

class ProfileCreationScreen extends StatefulWidget {
  const ProfileCreationScreen({super.key});

  @override
  State<ProfileCreationScreen> createState() => _ProfileCreationScreenState();
}

class _ProfileCreationScreenState extends State<ProfileCreationScreen> {
  final TextEditingController _birthdayController = TextEditingController();
  
  final Map<String, bool> _medicalConditions = {
    'Hypertension': false,
    'Diabetes': false,
    'Asthma': false,
    'Cardiovascular Disease': false,
    'Hyperthyroidism': false,
    'Other': false,
  };

  String get _selectedConditionsText {
    List<String> selected = _medicalConditions.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();
    if (selected.isEmpty) return "None selected";
    return selected.join(", ");
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2000, 1, 1),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _birthdayController.text = "${picked.toLocal()}".split(' ')[0];
      });
    }
  }

  void _showMultiSelectDialog() async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Select Medical Conditions"),
              content: SingleChildScrollView(
                child: ListBody(
                  children: _medicalConditions.keys.map((String key) {
                    return CheckboxListTile(
                      value: _medicalConditions[key],
                      title: Text(key),
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: Colors.blue,
                      onChanged: (bool? value) {
                        setDialogState(() {
                          _medicalConditions[key] = value ?? false;
                        });
                        setState(() {});
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("DONE"),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _showBmiInfoDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("What is BMI?"),
          content: const Text(
            "BMI (Body Mass Index) uses your height and weight to work out if your weight is healthy.\n\n"
            "BMI = Weight (kg) ÷ [Height (m)]²",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Got it"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    Color inputColor = isDark ? Colors.grey[800]! : Colors.white.withOpacity(0.9);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark 
              ? [const Color(0xFF1F1C2C), const Color(0xFF000000)]
              : [const Color(0xFFFFB75E), const Color(0xFFED8F03)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text("Complete Your Profile", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Personalized Health Data",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                "Select all conditions that apply to you.",
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),

              TextField(
                decoration: InputDecoration(
                  labelText: "Full Name", 
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _birthdayController,
                readOnly: true,
                onTap: () => _selectDate(context),
                decoration: InputDecoration(
                  labelText: "Birthday (YYYY-MM-DD)",
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
              ),
              const SizedBox(height: 16),

              InkWell(
                onTap: _showMultiSelectDialog,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: "Medical Conditions",
                    filled: true,
                    fillColor: inputColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _selectedConditionsText,
                          style: TextStyle(
                            color: _selectedConditionsText == "None selected" ? Colors.grey : (isDark ? Colors.white : Colors.black),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: "BMI", 
                        filled: true,
                        fillColor: inputColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.help_outline, color: Colors.white, size: 28),
                    onPressed: _showBmiInfoDialog,
                  ),
                ],
              ),
              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.blueGrey : Colors.white,
                    foregroundColor: isDark ? Colors.white : Colors.orange,
                  ),
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (context) => const PermissionsScreen()),
                    );
                  },
                  child: const Text("CONTINUE", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}