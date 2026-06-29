import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dashboard_screen.dart'; // UPDATED: Routing straight to the Dashboard

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _locationGranted = false;
  bool _bluetoothGranted = false;

  Future<void> _requestPermissions() async {
    // Request system permissions sequentially
    PermissionStatus locStatus = await Permission.location.request();
    PermissionStatus btScanStatus = await Permission.bluetoothScan.request();
    PermissionStatus btConnectStatus = await Permission.bluetoothConnect.request();

    setState(() {
      _locationGranted = locStatus.isGranted;
      _bluetoothGranted = btScanStatus.isGranted && btConnectStatus.isGranted;
    });

    // Once granted, bypass the old gatekeeper and go to the dashboard
    if (_locationGranted && _bluetoothGranted) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const DashboardScreen()),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Permissions are required to use Thermostat."),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;

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
          title: const Text("App Permissions", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.security, size: 60, color: Colors.white),
              const SizedBox(height: 16),
              const Text(
                "We need access",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                "Thermostat requires the following permissions to connect to your IoT device and fetch localized weather data.",
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 32),

              Container(
                decoration: BoxDecoration(
                  color: isDark ? Colors.black54 : Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    ListTile(
                      title: const Text("Location Services", style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text("Required for accurate weather APIs"),
                      trailing: Icon(
                        _locationGranted ? Icons.check_circle : Icons.circle_outlined,
                        color: _locationGranted ? Colors.green : Colors.grey,
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      title: const Text("Bluetooth & Nearby", style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text("Required to connect to Mk01"),
                      trailing: Icon(
                        _bluetoothGranted ? Icons.check_circle : Icons.circle_outlined,
                        color: _bluetoothGranted ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),
              
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.blueGrey : Colors.white,
                    foregroundColor: isDark ? Colors.white : Colors.orange,
                  ),
                  onPressed: _requestPermissions,
                  child: const Text("GRANT PERMISSIONS", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}