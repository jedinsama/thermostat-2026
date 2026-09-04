/// Onboarding / profile editor — Specific Objective 1's instrument.
library profile_screen;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/app_state.dart';
import '../core/risk_rules.dart';

class ProfileScreen extends StatefulWidget {
  final bool firstRun;
  const ProfileScreen({super.key, this.firstRun = false});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _restHr = TextEditingController();
  final _ecName = TextEditingController();
  final _ecPhone = TextEditingController();
  bool _cvd = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<AppState>().profile;
    if (p != null) {
      _name.text = p.userId;
      _age.text = p.ageYears.toStringAsFixed(0);
      _height.text = p.heightCm.toStringAsFixed(0);
      _weight.text = p.weightKg.toStringAsFixed(0);
      _restHr.text = p.restingHrBpm.toStringAsFixed(0);
      _cvd = p.cardiovascularCondition;
      _ecName.text = p.emergencyContactName;
      _ecPhone.text = p.emergencyContactPhone;
    }
  }

  String? _num(String? v, double lo, double hi, String what) {
    final d = double.tryParse(v ?? '');
    if (d == null) return 'enter $what';
    if (d < lo || d > hi) return '$what must be $lo–$hi';
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final p = UserProfile(
      userId: _name.text.trim(),
      ageYears: double.parse(_age.text),
      heightCm: double.parse(_height.text),
      weightKg: double.parse(_weight.text),
      restingHrBpm: double.parse(_restHr.text),
      cardiovascularCondition: _cvd,
      emergencyContactName: _ecName.text.trim(),
      emergencyContactPhone: _ecPhone.text.trim(),
    );
    await context.read<AppState>().saveProfile(p);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile saved')));
    if (widget.firstRun) {
      Navigator.pushReplacementNamed(context, '/dashboard');
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bmiPreview = () {
      final h = double.tryParse(_height.text), w = double.tryParse(_weight.text);
      if (h == null || w == null || h <= 0) return '—';
      return (w / ((h / 100) * (h / 100))).toStringAsFixed(1);
    }();

    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Welcome — set up your profile' : 'Health profile')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'enter a name' : null,
            ),
            TextFormField(
              controller: _age,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Age (years)'),
              validator: (v) => _num(v, 1, 119, 'age'),
            ),
            TextFormField(
              controller: _height,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height (cm)'),
              validator: (v) => _num(v, 51, 249, 'height'),
              onChanged: (_) => setState(() {}),
            ),
            TextFormField(
              controller: _weight,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Weight (kg)'),
              validator: (v) => _num(v, 11, 399, 'weight'),
              onChanged: (_) => setState(() {}),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Computed BMI: $bmiPreview'),
            ),
            TextFormField(
              controller: _restHr,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Resting heart rate (bpm)',
                  helperText: 'measure seated, after 5 minutes of rest'),
              validator: (v) => _num(v, 26, 129, 'resting HR'),
            ),
            SwitchListTile(
              value: _cvd,
              onChanged: (v) => setState(() => _cvd = v),
              title: const Text('Diagnosed cardiovascular condition'),
            ),
            const Divider(height: 32),
            TextFormField(
              controller: _ecName,
              decoration: const InputDecoration(labelText: 'Emergency contact name'),
            ),
            TextFormField(
              controller: _ecPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Emergency contact number'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save profile')),
          ],
        ),
      ),
    );
  }
}
