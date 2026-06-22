import 'package:flutter/material.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Thermostat"),
        centerTitle: true,
      ),
      // The Drawer widget creates the slide-out sidebar
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // User Profile Header
            const UserAccountsDrawerHeader(
              accountName: Text("Sample User"),
              accountEmail: Text("sampleuser@wmsu.edu.ph"),
              currentAccountPicture: CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, size: 40, color: Colors.blue),
              ),
              decoration: BoxDecoration(
                color: Colors.blue,
              ),
            ),
            // Connected Device Status
            ListTile(
              leading: const Icon(Icons.bluetooth_connected, color: Colors.green),
              title: const Text("Device Connected"),
              subtitle: const Text("Thermostat Mk01"),
              onTap: () {
                // TODO: Navigate to device management screen
                Navigator.pop(context); // Closes the drawer
              },
            ),
            const Divider(),
            // Settings Option
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text("Settings"),
              onTap: () {
                // TODO: Navigate to settings screen
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Status Warning Card (The core intervention system feature)
            Card(
              color: Colors.orange.shade100,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.deepOrange, size: 40),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "ELEVATED RISK LEVEL",
                            style: TextStyle(
                              color: Colors.deepOrange,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            "Temperature is rising. Please seek shade immediately and drink water.",
                            style: TextStyle(color: Colors.black87),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            const Text(
              "Real-Time Telemetry",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // 2. Metrics Grid
            // GridView.count automatically arranges our custom cards into a 2-column layout
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              shrinkWrap: true, // Prevents layout errors inside a SingleChildScrollView
              physics: const NeverScrollableScrollPhysics(), // Disables inner scrolling
              childAspectRatio: 1.0, // Adjusts the height/width ratio of the grid boxes
              children: [
                _buildMetricCard(Icons.location_city, "City", "Zamboanga", Colors.blueGrey),
                _buildMetricCard(Icons.thermostat, "Temperature", "36.2 °C", Colors.redAccent),
                _buildMetricCard(Icons.favorite, "Heartbeat", "94 BPM", Colors.pink),
                _buildMetricCard(Icons.water_drop, "Humidity", "72%", Colors.lightBlue),
                _buildMetricCard(Icons.cloud, "Weather", "Sunny", Colors.orange),
                _buildMetricCard(Icons.battery_charging_full, "Device Battery", "84%", Colors.green),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // A helper function to quickly generate consistent metric cards without repeating code
  Widget _buildMetricCard(IconData icon, String title, String value, Color iconColor) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: iconColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}