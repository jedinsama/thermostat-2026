// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:thermostat_app/main.dart';

void main() {
  testWidgets('App loads smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    // We pass isLoggedIn: false so it defaults to the Login Screen.
    await tester.pumpWidget(const ThermostatApp(isLoggedIn: false));

    // Verify that our app successfully loads the Login Screen
    // by checking if the welcome text exists on the screen.
    expect(find.text('Welcome to Thermostat'), findsOneWidget);
  });
}
