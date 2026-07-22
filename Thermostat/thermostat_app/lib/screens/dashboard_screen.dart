import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import 'login_screen.dart';
import 'emergency_contacts_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  // NEW: Weather header variable
  String currentLocationWeather = "Fetching weather...";

  BluetoothDevice? _connectedDevice;
  String currentHeartRate = "No device";
  String currentSpO2 = "No device";
  String currentBodyTemp = "No device"; // NEW: Body Temp State
  String currentHumidity = "No device";
  String currentBattery = "100%";
  String accountName = "Loading...";
  String accountEmail = "Loading...";

  List<FlSpot> _heartRateSpots = [];
  List<FlSpot> _spO2Spots = [];
  List<FlSpot> _bodyTempSpots = []; // Repurposed for Body Temp
  List<FlSpot> _humiditySpots = [];

  double _timeCounter = 0;
  int _selectedMetricIndex = 0;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  DateTime _currentTime = DateTime.now();
  Timer? _clockTimer;
  late AnimationController _gradientAnimController;

  Timer? _sosTimer;
  int _sosCountdown = 60;

  static const platform = MethodChannel('com.example.thermostat/sms');

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _refreshAllData();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
          _timeCounter++;
        });
      }
    });

    _gradientAnimController = AnimationController(
      duration: const Duration(seconds: 5),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _clockTimer?.cancel();
    _sosTimer?.cancel();
    _gradientAnimController.dispose();
    super.dispose();
  }

  // --- MULTI-GRAPH HELPER METHODS ---
  List<FlSpot> get _currentChartData {
    if (_selectedMetricIndex == 0) return _heartRateSpots;
    if (_selectedMetricIndex == 1) return _spO2Spots;
    if (_selectedMetricIndex == 2) return _bodyTempSpots;
    return _humiditySpots;
  }

  Color get _currentChartColor {
    if (_selectedMetricIndex == 0) return Colors.redAccent;
    if (_selectedMetricIndex == 1) return Colors.blueAccent;
    if (_selectedMetricIndex == 2) return Colors.orangeAccent;
    return Colors.lightBlue;
  }

  double get _currentMinY {
    if (_selectedMetricIndex == 0) return 50;
    if (_selectedMetricIndex == 1) return 80;
    if (_selectedMetricIndex == 2) return 35; // Human Body Temp Min
    return 30;
  }

  double get _currentMaxY {
    if (_selectedMetricIndex == 0) return 120;
    if (_selectedMetricIndex == 1) return 100;
    if (_selectedMetricIndex == 2) return 42; // Human Body Temp Max
    return 100;
  }

  String get _currentChartTitle {
    if (_selectedMetricIndex == 0) return "Heart Rate Trend (BPM)";
    if (_selectedMetricIndex == 1) return "Blood Oxygen Trend (%)";
    if (_selectedMetricIndex == 2) return "Body Temperature Trend (°C)";
    return "Environmental Humidity Trend (%)";
  }

  // --- SOS SIMULATION LOGIC ---
  void _startSosSimulation() {
    setState(() => _sosCountdown = 60);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _sosTimer?.cancel();
            _sosTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
              if (_sosCountdown > 0) {
                setDialogState(() => _sosCountdown--);
              } else {
                timer.cancel();
                Navigator.pop(context);
                _triggerEmergencySMS();
              }
            });

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Colors.redAccent, width: 2),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.redAccent,
                    size: 32,
                  ),
                  SizedBox(width: 8),
                  Text(
                    "Heatstroke Alert",
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Critical biometric levels detected. Please complete the wellness survey to verify your safety.",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    "$_sosCountdown",
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w900,
                      color: Colors.redAccent,
                    ),
                  ),
                  const Text(
                    "seconds remaining",
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      _sosTimer?.cancel();
                      Navigator.pop(context);
                      _openWellnessSurvey();
                    },
                    child: const Text(
                      "OPEN SURVEY",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => _sosTimer?.cancel());
  }

  void _openWellnessSurvey() {
    bool q1 = false, q2 = false, q3 = false, q4 = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSurveyState) {
            return AlertDialog(
              title: const Text(
                "Wellness Survey",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text("Are you in direct sunlight?"),
                      activeColor: Colors.orangeAccent,
                      value: q1,
                      onChanged: (val) => setSurveyState(() => q1 = val),
                    ),
                    SwitchListTile(
                      title: const Text("Is there any shade available?"),
                      activeColor: Colors.blueAccent,
                      value: q2,
                      onChanged: (val) => setSurveyState(() => q2 = val),
                    ),
                    SwitchListTile(
                      title: const Text("Did you bring any water?"),
                      activeColor: Colors.blueAccent,
                      value: q3,
                      onChanged: (val) => setSurveyState(() => q3 = val),
                    ),
                    SwitchListTile(
                      title: const Text("Is there any building nearby?"),
                      activeColor: Colors.blueAccent,
                      value: q4,
                      onChanged: (val) => setSurveyState(() => q4 = val),
                    ),
                  ],
                ),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _showAdvice(q1, q2, q3, q4);
                  },
                  child: const Text("SUBMIT"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAdvice(bool sunlight, bool shade, bool water, bool building) {
    String advice = "Immediate Actions to Take:\n\n";
    if (sunlight)
      advice +=
          "• Get out of direct sunlight immediately to lower your core temperature.\n";
    if (shade) advice += "• Move to the available shaded area and rest.\n";
    if (building) advice += "• Go inside the nearby building to cool down.\n";
    if (water) advice += "• Drink your water slowly. Do not gulp it.\n";
    if (!water) advice += "• Find a source of drinking water immediately.\n";

    if (!shade && !building && sunlight) {
      advice +=
          "\nCRITICAL: You must find cover immediately or contact someone for help.";
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "Medical Advice",
          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
        ),
        content: Text(advice, style: const TextStyle(height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("I UNDERSTAND"),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerEmergencySMS() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> contacts = prefs.getStringList('emergencyContacts') ?? [];
    List<String> numbers = [];

    for (String contact in contacts) {
      List<String> details = contact.split('|');
      if (details.length > 1 && details[1].isNotEmpty) {
        numbers.add(details[1]);
      }
    }

    if (numbers.isEmpty) return;

    String locationStr = "Fetching...";
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      locationStr = "Lat: ${position.latitude}, Lng: ${position.longitude}";
    } catch (e) {
      locationStr = "Unknown Location (GPS Disabled)";
    }

    String timeStamp =
        "${_currentTime.hour}:${_currentTime.minute.toString().padLeft(2, '0')}";
    String message =
        "SOS EMERGENCY: $accountName is in danger of a heatstroke and failed to respond to the safety check. Location: $locationStr. Time: $timeStamp. Please check on them immediately.";

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.red[900],
          title: const Text(
            "SOS DEPLOYED",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            "A distress signal is being sent to:\n${numbers.join(', ')}\n\nPayload:\n$message",
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "DISMISS ALERT",
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }

    PermissionStatus smsPermission = await Permission.sms.request();
    if (smsPermission.isGranted) {
      for (String number in numbers) {
        try {
          await platform.invokeMethod('sendSms', {
            'phone': number,
            'msg': message,
          });
        } catch (e) {
          print("Native Background SMS Error for $number: $e");
        }
      }
    } else {
      String emergencyNumbers = numbers.join(',');
      final Uri smsUri = Uri(
        scheme: 'sms',
        path: emergencyNumbers,
        queryParameters: {'body': message},
      );
      try {
        if (await canLaunchUrl(smsUri)) await launchUrl(smsUri);
      } catch (e) {
        print("Could not launch SMS app: $e");
      }
    }
  }

  String _getFormattedTime() {
    int hour = _currentTime.hour > 12
        ? _currentTime.hour - 12
        : (_currentTime.hour == 0 ? 12 : _currentTime.hour);
    String minute = _currentTime.minute.toString().padLeft(2, '0');
    String amPm = _currentTime.hour >= 12 ? "PM" : "AM";
    return "$hour:$minute $amPm";
  }

  List<Color> _getTimeOfDayColors() {
    int hour = _currentTime.hour;
    if (hour >= 5 && hour < 12)
      return [const Color(0xFFA1C4FD), const Color(0xFFC2E9FB)];
    else if (hour >= 12 && hour < 18)
      return [const Color(0xFFFF9A44), const Color(0xFFFC6076)];
    else
      return [const Color(0xFF1F1C2C), const Color(0xFF928DAB)];
  }

  Future<void> _loadUserProfile() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        accountName = prefs.getString('userName') ?? "Student User";
        accountEmail = prefs.getString('userEmail') ?? "student@wmsu.edu.ph";
      });
    }
  }

  Future<void> _refreshAllData() async {
    await getRealTimeWeather();
    if (_connectedDevice == null) await _scanForHardware();
  }

  Future<void> _scanForHardware() async {
    try {
      BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) return;

      FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          String deviceName = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;

          bool isOurDevice =
              deviceName.toUpperCase().contains("THERMOST") ||
              deviceName.toUpperCase().contains("MK1") ||
              r.advertisementData.serviceUuids.contains(
                Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b"),
              );

          if (isOurDevice && _connectedDevice == null) {
            FlutterBluePlus.stopScan();
            try {
              await r.device.connect(license: License.nonprofit);
              if (mounted) {
                setState(() {
                  _connectedDevice = r.device;

                  currentHeartRate = "-- BPM";
                  currentSpO2 = "-- %";
                  currentBodyTemp = "-- °C";
                  currentHumidity = "-- %";

                  _heartRateSpots.clear();
                  _spO2Spots.clear();
                  _bodyTempSpots.clear();
                  _humiditySpots.clear();
                  _timeCounter = 0;
                });

                _setupBluetoothListeners();
                _monitorConnection();
              }
            } catch (e) {
              print("Connection failed: $e");
            }
          }
        }
      });
    } catch (e) {
      print("Scan failed. Error: $e");
    }
  }

  void _monitorConnection() {
    _connectionSub = _connectedDevice?.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        setState(() {
          _connectedDevice = null;

          currentHeartRate = "No device";
          currentSpO2 = "No device";
          currentBodyTemp = "No device";

          getRealTimeWeather(); // Re-trigger the API for Humidity fallback

          _heartRateSpots.clear();
          _spO2Spots.clear();
          _bodyTempSpots.clear();
          _humiditySpots.clear();
        });
      }
    });
  }

  Future<void> _setupBluetoothListeners() async {
    if (_connectedDevice == null) return;

    try {
      await _connectedDevice!.clearGattCache();
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      print("GATT Cache Clear skipped: $e");
    }

    try {
      await _connectedDevice!.requestMtu(512);
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      print("MTU Request skipped: $e");
    }

    List<BluetoothService> services = await _connectedDevice!
        .discoverServices();

    BluetoothCharacteristic? hrChar;
    BluetoothCharacteristic? spo2Char;
    BluetoothCharacteristic? humChar;
    BluetoothCharacteristic? bodyTempChar; // NEW

    for (BluetoothService service in services) {
      if (service.uuid.toString().toLowerCase() ==
          "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
        for (BluetoothCharacteristic char in service.characteristics) {
          String uuid = char.uuid.toString().toLowerCase();

          if (uuid == "beb5483e-36e1-4688-b7f5-ea07361b26a8") hrChar = char;
          if (uuid == "8a530eb1-4638-4e3a-b8cb-403332462e24") spo2Char = char;
          if (uuid == "b78ed4dc-93e1-419f-bba3-21c81c4eec49") humChar = char;
          if (uuid == "f4705a66-70e6-4277-bb89-cdb37dc1d848")
            bodyTempChar = char; // NEW
        }
      }
    }

    Future<void> safeSubscribe(
      BluetoothCharacteristic? char,
      Function(String) onData,
    ) async {
      if (char == null) return;
      try {
        await char.setNotifyValue(true);
        char.lastValueStream.listen((value) {
          if (value.isNotEmpty && mounted) {
            onData(String.fromCharCodes(value).trim());
          }
        });
        await Future.delayed(const Duration(milliseconds: 600));
      } catch (e) {
        print("Failed to subscribe to ${char.uuid}: $e");
      }
    }

    await safeSubscribe(hrChar, (data) {
      double? val = double.tryParse(data);
      setState(() {
        currentHeartRate = "$data BPM";
        if (val != null) {
          _heartRateSpots.add(FlSpot(_timeCounter, val));
          if (_heartRateSpots.length > 20) _heartRateSpots.removeAt(0);
        }
      });
    });

    await safeSubscribe(spo2Char, (data) {
      double? val = double.tryParse(data);
      setState(() {
        currentSpO2 = "$data %";
        if (val != null) {
          _spO2Spots.add(FlSpot(_timeCounter, val));
          if (_spO2Spots.length > 20) _spO2Spots.removeAt(0);
        }
      });
    });

    // NEW: Body Temperature Subscribe
    await safeSubscribe(bodyTempChar, (data) {
      double? val = double.tryParse(data);
      setState(() {
        currentBodyTemp = "$data °C";
        if (val != null) {
          _bodyTempSpots.add(FlSpot(_timeCounter, val));
          if (_bodyTempSpots.length > 20) _bodyTempSpots.removeAt(0);
        }
      });
    });

    await safeSubscribe(humChar, (data) {
      double? val = double.tryParse(data);
      setState(() {
        currentHumidity = "$data %";
        if (val != null) {
          _humiditySpots.add(FlSpot(_timeCounter, val));
          if (_humiditySpots.length > 20) _humiditySpots.removeAt(0);
        }
      });
    });
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
            // NEW: Combines City Name and Weather for the header
            currentLocationWeather =
                "Zamboanga City - ${data['main']['temp'].toStringAsFixed(1)} °C";

            if (_connectedDevice == null) {
              currentHumidity = "${data['main']['humidity']}%";
            }
          });
        }
      }
    } catch (e) {
      print("Weather fetch failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    bool isNightModeTime = _currentTime.hour >= 18 || _currentTime.hour < 5;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Image.asset('assets/images/thermostat_icon.png', height: 28),
        centerTitle: true,
        backgroundColor: isDark ? Colors.black : const Color(0xFFF4F6F8),
        elevation: 0,
        iconTheme: IconThemeData(
          color: isDark ? Colors.white : Colors.blueAccent,
        ),
      ),
      drawer: Drawer(
        backgroundColor: isDark ? Colors.grey[900] : Colors.white,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                accountName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              accountEmail: Text(accountEmail),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, size: 40, color: Colors.blueAccent),
              ),
              decoration: const BoxDecoration(color: Colors.blueAccent),
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
                    ? "THERMOST"
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
              leading: const Icon(Icons.contact_phone, color: Colors.redAccent),
              title: const Text(
                "Emergency Contacts",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const EmergencyContactsScreen(),
                  ),
                );
              },
            ),

            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: const Text(
                "Log Out",
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                SharedPreferences prefs = await SharedPreferences.getInstance();
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
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAllData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                height: 220,
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      spreadRadius: 2,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    AnimatedBuilder(
                      animation: _gradientAnimController,
                      builder: (context, child) {
                        return Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: _getTimeOfDayColors(),
                              begin: Alignment(
                                -1.0 + (_gradientAnimController.value * 2),
                                -1.0,
                              ),
                              end: Alignment(
                                1.0 - (_gradientAnimController.value * 2),
                                1.0,
                              ),
                            ),
                          ),
                        );
                      },
                    ),

                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Image.asset(
                        'assets/images/hill_parallax.png',
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),

                    Positioned(
                      top: 16,
                      left: 16,
                      child: Row(
                        children: [
                          Text(
                            currentBattery,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: isNightModeTime
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.battery_full,
                            color: isNightModeTime
                                ? Colors.greenAccent
                                : Colors.green,
                            size: 24,
                          ),
                        ],
                      ),
                    ),

                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _getFormattedTime(),
                            style: TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.w900,
                              color: isNightModeTime
                                  ? Colors.white
                                  : Colors.black,
                              letterSpacing: -1,
                            ),
                          ),
                          // NEW: API Weather Displayed Here
                          Text(
                            currentLocationWeather,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isNightModeTime
                                  ? Colors.white70
                                  : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.0,
                children: [
                  // NEW: Body Temperature Card
                  _buildMetricCard(
                    context,
                    Icons.thermostat,
                    "Body Temperature",
                    currentBodyTemp,
                    Colors.orangeAccent,
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
                ],
              ),
              const SizedBox(height: 24),

              Center(
                child: Text(
                  "Live Telemetry",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Container(
                height: 250,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[900] : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentChartTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 12),

                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text("Heart Rate"),
                            selected: _selectedMetricIndex == 0,
                            onSelected: (bool selected) =>
                                setState(() => _selectedMetricIndex = 0),
                            selectedColor: Colors.redAccent.withOpacity(0.2),
                            labelStyle: TextStyle(
                              color: _selectedMetricIndex == 0
                                  ? Colors.redAccent
                                  : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text("SpO2"),
                            selected: _selectedMetricIndex == 1,
                            onSelected: (bool selected) =>
                                setState(() => _selectedMetricIndex = 1),
                            selectedColor: Colors.blueAccent.withOpacity(0.2),
                            labelStyle: TextStyle(
                              color: _selectedMetricIndex == 1
                                  ? Colors.blueAccent
                                  : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            // NEW: Body Temp Tab
                            label: const Text("Body Temp"),
                            selected: _selectedMetricIndex == 2,
                            onSelected: (bool selected) =>
                                setState(() => _selectedMetricIndex = 2),
                            selectedColor: Colors.orangeAccent.withOpacity(0.2),
                            labelStyle: TextStyle(
                              color: _selectedMetricIndex == 2
                                  ? Colors.orangeAccent
                                  : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text("Humidity"),
                            selected: _selectedMetricIndex == 3,
                            onSelected: (bool selected) =>
                                setState(() => _selectedMetricIndex = 3),
                            selectedColor: Colors.lightBlue.withOpacity(0.2),
                            labelStyle: TextStyle(
                              color: _selectedMetricIndex == 3
                                  ? Colors.lightBlue
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    Expanded(
                      child: _connectedDevice == null
                          ? const Center(
                              child: Text(
                                "Data not available.\nPlease connect to a Thermostat device.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 14,
                                  height: 1.5,
                                ),
                              ),
                            )
                          : LineChart(
                              LineChartData(
                                gridData: FlGridData(show: false),
                                titlesData: FlTitlesData(show: false),
                                borderData: FlBorderData(show: false),
                                minY: _currentMinY,
                                maxY: _currentMaxY,
                                minX: _timeCounter > 20 ? _timeCounter - 20 : 0,
                                maxX: _timeCounter == 0 ? 1 : _timeCounter,
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: _currentChartData.isEmpty
                                        ? const [FlSpot(0, 0)]
                                        : _currentChartData,
                                    isCurved: true,
                                    color: _currentChartColor,
                                    barWidth: 3,
                                    isStrokeCapRound: true,
                                    dotData: FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      color: _currentChartColor.withOpacity(
                                        0.1,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                  ),
                  icon: const Icon(Icons.warning_amber_rounded, size: 28),
                  label: const Text(
                    "TRIGGER SOS SIMULATION",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 1.2,
                    ),
                  ),
                  onPressed: _startSosSimulation,
                ),
              ),
              const SizedBox(height: 32),
            ],
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
    double fontSize = value.contains("No device") ? 14 : 20;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.transparent : Colors.grey[200]!,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
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
                color: isDark ? Colors.white70 : Colors.grey[500],
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
