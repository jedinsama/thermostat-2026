import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // NEW: First and Last Name Controllers
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  
  final TextEditingController _emergencyNameController = TextEditingController();
  final TextEditingController _emergencyNumberController = TextEditingController();

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
                      activeColor: Colors.blueAccent,
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
                  child: const Text("DONE", style: TextStyle(color: Colors.blueAccent)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  Future<void> _registerUser() async {
    if (_emergencyNameController.text.isEmpty || _emergencyNumberController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please fill in all Emergency Contact fields."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    SharedPreferences prefs = await SharedPreferences.getInstance();
    
    // Save standard credentials
    await prefs.setString('savedFirstName', _firstNameController.text);
    await prefs.setString('savedLastName', _lastNameController.text);
    await prefs.setString('savedEmail', _emailController.text);
    await prefs.setString('savedPassword', _passwordController.text);
    await prefs.setString('savedMedical', _selectedConditionsText);

    List<String> initialContacts = ["${_emergencyNameController.text}|${_emergencyNumberController.text}"];
    await prefs.setStringList('emergencyContacts', initialContacts);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Registration Successful! Please Log In.")),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    Color inputColor = isDark ? Colors.grey[900]! : Colors.grey[100]!;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      appBar: AppBar(
        title: Text("Create Account", style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black87),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: const Icon(Icons.person_add, size: 80, color: Colors.blueAccent)),
              const SizedBox(height: 32),
              
              const Text("Account Details", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 12),

              // NEW: First Name
              TextField(
                controller: _firstNameController,
                decoration: InputDecoration(
                  labelText: "First Name",
                  prefixIcon: const Icon(Icons.person, color: Colors.blueAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),

              // NEW: Last Name
              TextField(
                controller: _lastNameController,
                decoration: InputDecoration(
                  labelText: "Last Name",
                  prefixIcon: const Icon(Icons.person_outline, color: Colors.blueAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: "Email",
                  prefixIcon: const Icon(Icons.email, color: Colors.blueAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Password",
                  prefixIcon: const Icon(Icons.lock, color: Colors.blueAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Confirm Password",
                  prefixIcon: const Icon(Icons.lock_outline, color: Colors.blueAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              
              const SizedBox(height: 24),
              Divider(color: isDark ? Colors.grey[800] : Colors.grey[300]),
              const SizedBox(height: 24),

              const Text("Health & Safety", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 12),

              InkWell(
                onTap: _showMultiSelectDialog,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: "Medical Conditions",
                    prefixIcon: const Icon(Icons.local_hospital, color: Colors.blueAccent),
                    filled: true,
                    fillColor: inputColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _selectedConditionsText,
                          style: TextStyle(
                            color: _selectedConditionsText == "None selected" ? Colors.grey : (isDark ? Colors.white : Colors.black87),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, color: Colors.blueAccent),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _emergencyNameController,
                decoration: InputDecoration(
                  labelText: "Emergency Contact Name",
                  hintText: "Please fill",
                  hintStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  prefixIcon: const Icon(Icons.person, color: Colors.redAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _emergencyNumberController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: "Emergency Contact Number",
                  hintText: "Please fill",
                  hintStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  prefixIcon: const Icon(Icons.phone, color: Colors.redAccent),
                  filled: true,
                  fillColor: inputColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),

              const SizedBox(height: 32),
              
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _registerUser,
                  child: const Text("REGISTER", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}