/// Wellness survey — fires at Danger, feeds personal calibration, and its
/// non-response window is the SOS trigger (handled in AppState).
library survey_dialog;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/app_state.dart';

bool _surveyShowing = false;

Future<void> maybeShowSurvey(BuildContext context) async {
  final state = context.read<AppState>();
  if (!state.surveyPending || _surveyShowing) return;
  _surveyShowing = true;
  final symptoms = <String, bool>{
    'Dizziness or light-headedness': false,
    'Nausea': false,
    'Headache': false,
    'Muscle cramps': false,
    'Unusual fatigue or confusion': false,
  };
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Quick check — how are you feeling?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your readings suggest elevated heat risk. '
                'Tick anything you are feeling right now:'),
            ...symptoms.keys.map((s) => CheckboxListTile(
                  dense: true,
                  value: symptoms[s],
                  onChanged: (v) => setState(() => symptoms[s] = v ?? false),
                  title: Text(s, style: const TextStyle(fontSize: 14)),
                )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.answerSurvey(hadSymptoms: symptoms.values.any((v) => v));
            },
            child: const Text('Submit'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.answerSurvey(hadSymptoms: false);
            },
            child: const Text("I'm fine"),
          ),
        ],
      ),
    ),
  );
  _surveyShowing = false;
}
