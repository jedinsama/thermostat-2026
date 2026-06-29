import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../main.dart';
import 'login_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key}); // No longer requires a device to open!

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Weather variables
  String currentTemp = "Loading...";
  String currentHumidity = "Loading...";

  // Hardware variables default to offline state
  BluetoothDevice? _connectedDevice;
  String currentHeartRate = "No device detected";
  String currentSpO2 = "No device detected";

  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  @override
  void initState() {
    super.initState();
    _refreshAllData(); // Fetches weather and scans for Bluetooth on startup
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    super.dispose();
  }

  // The master refresh function triggered by pulling down
  Future<void> _refreshAllData() async {
    await getRealTimeWeather();

    // Only scan if we aren't already connected
    if (_connectedDevice == null) {
      await _scanForHardware();
    }
  }

  Future<void> _scanForHardware() async {
    // Scan exclusively for the ESP32 UUID
    FlutterBluePlus.startScan(
      withServices: [Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b")],
      timeout: const Duration(seconds: 4), // Quick 4-second sweep
    );

    FlutterBluePlus.scanResults.listen((results) async {
      if (results.isNotEmpty && _connectedDevice == null) {
        ScanResult r = results.first;
        FlutterBluePlus.stopScan();

        try {
          await r.device.connect(license: License.nonprofit);

          if (mounted) {
            setState(() {
              _connectedDevice = r.device;
              currentHeartRate = "-- BPM"; // Resets to empty until data flows
              currentSpO2 = "-- %";
            });
            _setupBluetoothListeners();
            _monitorConnection();
          }
        } catch (e) {
          print("Connection failed: $e");
        }
      }
    });
  }

  void _monitorConnection() {
    _connectionSub = _connectedDevice?.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        if (mounted) {
          setState(() {
            _connectedDevice = null;
            currentHeartRate = "No device detected";
            currentSpO2 = "No device detected";
          });
        }
      }
    });
  }

  Future<void> _setupBluetoothListeners() async {
    if (_connectedDevice == null) return;

    List<BluetoothService> services = await _connectedDevice!
        .discoverServices();

    for (BluetoothService service in services) {
      if (service.uuid.toString() == "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
        for (BluetoothCharacteristic char in service.characteristics) {
          // Listen to Heart Rate
          if (char.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await char.setNotifyValue(true);
            char.lastValueStream.listen((value) {
              if (value.isNotEmpty && mounted) {
                setState(() {
                  currentHeartRate = "${String.fromCharCodes(value)} BPM";
                });
              }
            });
          }

          // Listen to SpO2
          if (char.uuid.toString() == "8a530eb1-4638-4e3a-b8cb-403332462e24") {
            await char.setNotifyValue(true);
            char.lastValueStream.listen((value) {
              if (value.isNotEmpty && mounted) {
                setState(() {
                  currentSpO2 = "${String.fromCharCodes(value)} %";
                });
              }
            });
          }
        }
      }
    }
  }

  Future<void> getRealTimeWeather() async {
    const apiKey = "2d8563d4f7f056db1d75a0dfc0cc048a";
    const city = "Zamboanga, PH";

    final url = Uri.parse(
      "https://api.openweathermap.org/data/2.5/weather?q=$city&appid=$apiKey&units=metric",
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            currentTemp = "${data['main']['temp'].toStringAsFixed(1)} °C";
            currentHumidity = "${data['main']['humidity']}%";
          });
        }
      }
    } catch (e) {
      print("Failed to fetch weather: $e");
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
          title: const Text(
            "Thermostat",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        drawer: Drawer(
          backgroundColor: isDark ? Colors.grey[900] : Colors.white,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const UserAccountsDrawerHeader(
                accountName: Text(
                  "Test",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                accountEmail: Text("test@wmsu.edu.ph"),
                currentAccountPicture: CircleAvatar(
                  backgroundColor: Colors.white,
                  child: Icon(Icons.person, size: 40, color: Colors.orange),
                ),
                decoration: BoxDecoration(color: Colors.orange),
              ),
              ListTile(
                leading: Icon(
                  _connectedDevice != null
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: _connectedDevice != null ? Colors.green : Colors.grey,
                ),
                title: Text(
                  _connectedDevice != null ? "Device Connected" : "No Device",
                ),
                subtitle: Text(
                  _connectedDevice != null
                      ? "Thermostat Mk01"
                      : "Pull dashboard to scan",
                ),
                onTap: () => Navigator.pop(context),
              ),
              const Divider(),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: themeNotifier,
                builder: (context, currentMode, child) {
                  return SwitchListTile(
                    title: const Text("Night Mode"),
                    secondary: Icon(
                      currentMode == ThemeMode.dark
                          ? Icons.dark_mode
                          : Icons.light_mode,
                    ),
                    value: currentMode == ThemeMode.dark,
                    onChanged: (bool isNight) {
                      themeNotifier.value = isNight
                          ? ThemeMode.dark
                          : ThemeMode.light;
                    },
                  );
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text("Settings"),
                onTap: () => Navigator.pop(context),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  "Log Out",
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(context);

                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: const Text("Log Out"),
                        content: const Text(
                          "Are you sure you want to log out of Thermostat?",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text("No"),
                          ),
                          TextButton(
                            onPressed: () async {
                              SharedPreferences prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool('isLoggedIn', false);

                              if (context.mounted) {
                                Navigator.pushAndRemoveUntil(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const LoginScreen(),
                                  ),
                                  (route) => false,
                                );
                              }
                            },
                            child: const Text(
                              "Yes",
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _refreshAllData, // Triggers Weather + Bluetooth Scan
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Real-Time Telemetry",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),

                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.0,
                  children: [
                    _buildMetricCard(
                      context,
                      Icons.location_city,
                      "City",
                      "Zamboanga",
                      Colors.blueGrey,
                    ),
                    _buildMetricCard(
                      context,
                      Icons.thermostat,
                      "Temperature",
                      currentTemp,
                      Colors.redAccent,
                    ),
                    _buildMetricCard(
                      context,
                      Icons.favorite,
                      "Heart Rate",
                      currentHeartRate,
                      Colors.pinkAccent,
                    ),
                    _buildMetricCard(
                      context,
                      Icons.bloodtype,
                      "Blood Oxygen",
                      currentSpO2,
                      Colors.red,
                    ),
                    _buildMetricCard(
                      context,
                      Icons.water_drop,
                      "Humidity",
                      currentHumidity,
                      Colors.lightBlue,
                    ),
                    _buildMetricCard(
                      context,
                      _connectedDevice != null
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                      "Device",
                      _connectedDevice != null ? "Connected" : "Offline",
                      _connectedDevice != null ? Colors.green : Colors.grey,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard(
    BuildContext context,
    IconData icon,
    String title,
    String value,
    Color iconColor,
  ) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    // Adjust text size dynamically if it says "No device detected"
    double fontSize = value == "No device detected" ? 12 : 18;

    return Card(
      elevation: 0,
      color: isDark
          ? Colors.white.withOpacity(0.1)
          : Colors.white.withOpacity(0.85),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.2), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: iconColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
