import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dashboard_screen.dart'; 

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _locationGranted = false;
  bool _bluetoothGranted = false;

  Future<void> _requestPermissions() async {
    PermissionStatus locStatus = await Permission.location.request();
    PermissionStatus btScanStatus = await Permission.bluetoothScan.request();
    PermissionStatus btConnectStatus = await Permission.bluetoothConnect.request();

    setState(() {
      _locationGranted = locStatus.isGranted;
      _bluetoothGranted = btScanStatus.isGranted && btConnectStatus.isGranted;
    });

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
    Color textColor = isDark ? Colors.white : Colors.black87;
    Color subTextColor = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      appBar: AppBar(
        title: Text("App Permissions", style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.security, size: 60, color: Colors.blueAccent),
            const SizedBox(height: 24),
            Text(
              "We need access",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: textColor),
            ),
            const SizedBox(height: 12),
            Text(
              "Thermostat requires the following permissions to connect to your IoT device and fetch localized weather data.",
              style: TextStyle(color: subTextColor, fontSize: 16, height: 1.5),
            ),
            const SizedBox(height: 40),

            Container(
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[900] : Colors.grey[100],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!),
              ),
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    title: Text("Location Services", style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
                    subtitle: Text("Required for accurate weather APIs", style: TextStyle(color: subTextColor)),
                    trailing: Icon(
                      _locationGranted ? Icons.check_circle : Icons.circle_outlined,
                      color: _locationGranted ? Colors.green : Colors.grey,
                      size: 28,
                    ),
                  ),
                  Divider(height: 1, color: isDark ? Colors.grey[800] : Colors.grey[300]),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    title: Text("Bluetooth & Nearby", style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
                    subtitle: Text("Required to connect to Mk01", style: TextStyle(color: subTextColor)),
                    trailing: Icon(
                      _bluetoothGranted ? Icons.check_circle : Icons.circle_outlined,
                      color: _bluetoothGranted ? Colors.green : Colors.grey,
                      size: 28,
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
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _requestPermissions,
                child: const Text("GRANT PERMISSIONS", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}