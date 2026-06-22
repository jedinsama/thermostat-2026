# THERMOSTAT: Heat Stroke Risk Prediction & Mitigation

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)
![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white)
![Python](https://img.shields.io/badge/python-3670A0?style=for-the-badge&logo=python&logoColor=ffdd54)
![C++](https://img.shields.io/badge/c++-%2300599C.svg?style=for-the-badge&logo=c%2B%2B&logoColor=white)

An IoT-enabled, machine learning-based mobile application designed to accurately predict heatstroke risks based on individualized user profiling and real-time hyper-local environmental data. 

## 📖 Overview
General weather advisories often fail to account for the unique physiological differences of individuals and their immediate environments. Thermostat serves as a personalized early warning tool that bridges this gap. By integrating an IoT wearable device with a predictive Machine Learning engine, the system continuously monitors temperature, humidity, and biometric responses to deliver actionable mitigation strategies before dangerous thermal stress occurs.

## ✨ Key Features
* **Real-Time Telemetry Dashboard:** View live data including surrounding temperature, humidity, heart rate (BPM), and SpO2 levels.
* **Personalized User Profiling:** Dynamic risk calculation heavily influenced by the user's age, BMI, and pre-existing medical conditions.
* **Machine Learning Risk Engine:** Calculates a personalized heatstroke risk score using a trained classification model.
* **Interactive Health Interventions:** Automated alerts that prompt users to evaluate their physical state (e.g., hydration levels, dizziness) when environmental thresholds are breached.
* **BLE Integration:** Seamless offline data transmission from the wearable device to the mobile application via Bluetooth Low Energy.

## 🛠️ Technology Stack
**Frontend (Mobile Application)**
* Framework: Flutter / Dart
* Key Packages: `flutter_blue_plus` (BLE communication), `http` (API requests)

**Backend & AI**
* API Framework: Python / Flask
* Machine Learning: TensorFlow / Scikit-learn
* Data Handling: JSON RESTful API

**Hardware / IoT Wearable**
* Microcontroller: ESP32-C3 SuperMini (Bluetooth-enabled)
* Environmental Sensor: BME280 (Temperature & Humidity)
* Biometric Sensor: MAX30102 (Heart Rate & SpO2)
* Power: Rechargeable LiPo battery system

## 🚀 Getting Started (Mobile App)

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) installed and added to your system PATH.
* An IDE such as VS Code or Android Studio.
* A physical Android device with **USB Debugging** enabled (Emulators do not support BLE testing).

### Installation
1. Clone the repository:
   ```bash
   git clone [https://github.com/yourusername/thermostat-app.git](https://github.com/yourusername/thermostat-app.git)
