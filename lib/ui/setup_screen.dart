import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/energy.dart';
import 'destination_screen.dart';

/// Asked at every app start: current charge. The car's details are remembered
/// after the first time, and can be changed here.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const _consumptionOptions = [15.0, 20.0, 25.0, 30.0];
  static const _batteryOptions = {'VF 6 / VF 7 Earth': 59.6, 'VF 7 Wind / Sky': 70.8};
  static const _consumptionKey = 'kwhPer100KmAt80';
  static const _batteryKey = 'batteryKwh';
  static const _rangeKey = 'ratedRangeKm';
  static const _ratingKey = 'rangeRating';
  static const _dragKey = 'dragCd';
  static const _maxChargeKey = 'maxChargeKw';

  final _soc = TextEditingController();
  final _consumption = TextEditingController(text: '18');
  final _battery = TextEditingController(text: '59.6');
  final _range = TextEditingController();
  final _drag = TextEditingController(text: '0.29');
  final _maxCharge = TextEditingController();
  var _rating = RangeRating.arai;

  /// Shown open until the car's details have been saved once.
  bool _carKnown = false;

  @override
  void initState() {
    super.initState();
    _restoreLastValues();
  }

  Future<void> _restoreLastValues() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        final consumption = prefs.getDouble(_consumptionKey);
        final range = prefs.getDouble(_rangeKey);
        final maxCharge = prefs.getDouble(_maxChargeKey);
        if (consumption != null) _consumption.text = _format(consumption);
        _battery.text = _format(prefs.getDouble(_batteryKey) ?? 59.6);
        if (range != null) _range.text = _format(range);
        _drag.text = _format(prefs.getDouble(_dragKey) ?? EnergyModel.defaultDragCd);
        if (maxCharge != null) _maxCharge.text = _format(maxCharge);
        _rating = RangeRating.values.asNameMap()[prefs.getString(_ratingKey)] ?? RangeRating.arai;
        _carKnown = consumption != null && range != null;
      });
    } catch (_) {
      // First-run defaults are fine.
    }
  }

  String _format(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

  double? _parse(TextEditingController c, double min, double max) {
    final v = double.tryParse(c.text);
    return v != null && v >= min && v <= max ? v : null;
  }

  double? get _socValue {
    final v = double.tryParse(_soc.text);
    return v != null && v > 0 && v <= 100 ? v : null;
  }

  double? get _consumptionValue => _parse(_consumption, 5, 60);
  double? get _batteryValue => _parse(_battery, 10, 200);
  double? get _rangeValue => _parse(_range, 50, 1500);
  double? get _dragValue => _parse(_drag, 0.15, 0.6);

  /// Optional: blank assumes a typical limit.
  double? get _maxChargeValue => _parse(_maxCharge, 10, 500);
  bool get _maxChargeValid => _maxCharge.text.isEmpty || _maxChargeValue != null;

  bool get _carValid =>
      _consumptionValue != null &&
      _batteryValue != null &&
      _rangeValue != null &&
      _dragValue != null &&
      _maxChargeValid;

  Future<void> _continue() async {
    final soc = _socValue!;
    final energy = EnergyModel(
      kwhPer100Km: _consumptionValue!,
      batteryKwh: _batteryValue!,
      ratedRangeKm: _rangeValue,
      rating: _rating,
      dragCd: _dragValue!,
      maxChargeKw: _maxChargeValue,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_consumptionKey, energy.kwhPer100Km);
      await prefs.setDouble(_batteryKey, energy.batteryKwh);
      await prefs.setDouble(_rangeKey, energy.ratedRangeKm!);
      await prefs.setString(_ratingKey, energy.rating.name);
      await prefs.setDouble(_dragKey, energy.dragCd);
      if (energy.maxChargeKw == null) {
        await prefs.remove(_maxChargeKey);
      } else {
        await prefs.setDouble(_maxChargeKey, energy.maxChargeKw!);
      }
    } catch (_) {
      // Not remembering is harmless.
    }
    if (!mounted) return;
    setState(() => _carKnown = true);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DestinationScreen(startSoc: soc, energy: energy),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canContinue = _socValue != null && _carValid;
    return Scaffold(
      appBar: AppBar(title: const Text('Vinfast Copilot')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!AppConfig.hasApiKey) const _MissingKeyBanner(),
            Text('Battery charge right now', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              key: const Key('socField'),
              controller: _soc,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              style: theme.textTheme.headlineMedium,
              decoration: InputDecoration(
                suffixText: '%',
                hintText: '80',
                border: const OutlineInputBorder(),
                errorText: _soc.text.isNotEmpty && _socValue == null ? 'Enter 1 to 100' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                key: ValueKey(_carKnown),
                initiallyExpanded: !_carKnown || !_carValid,
                title: Text('Your car', style: theme.textTheme.titleMedium),
                subtitle: Text(_carSummary),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: _carFields(theme),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              key: const Key('continueButton'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: canContinue ? _continue : null,
              child: const Text('Where to?'),
            ),
          ],
        ),
      ),
    );
  }

  String get _carSummary {
    if (!_carValid) return 'Needs a few details';
    final rating = _rating == RangeRating.arai ? 'ARAI' : 'EPA';
    return '${_battery.text} kWh · ${_consumption.text} kWh/100 km at 80 · '
        '${_range.text} km $rating · Cd ${_drag.text}';
  }

  List<Widget> _carFields(ThemeData theme) => [
        Text('Consumption at a steady 80 km/h', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _QuickOptions(
          options: {for (final v in _consumptionOptions) '${v.round()}': v},
          current: double.tryParse(_consumption.text),
          onSelected: (v) => setState(() => _consumption.text = _format(v)),
        ),
        const SizedBox(height: 12),
        _NumberField(
          fieldKey: const Key('consumptionField'),
          controller: _consumption,
          suffix: 'kWh / 100 km',
          error: _consumptionValue == null ? 'Enter 5 to 60' : null,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Battery size', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _QuickOptions(
          options: _batteryOptions,
          current: double.tryParse(_battery.text),
          onSelected: (v) => setState(() => _battery.text = _format(v)),
        ),
        const SizedBox(height: 12),
        _NumberField(
          fieldKey: const Key('batteryField'),
          controller: _battery,
          suffix: 'kWh',
          error: _batteryValue == null ? 'Enter 10 to 200' : null,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Rated range', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<RangeRating>(
          segments: const [
            ButtonSegment(value: RangeRating.arai, label: Text('ARAI')),
            ButtonSegment(value: RangeRating.epa, label: Text('EPA')),
          ],
          selected: {_rating},
          onSelectionChanged: (s) => setState(() => _rating = s.first),
        ),
        const SizedBox(height: 12),
        _NumberField(
          fieldKey: const Key('rangeField'),
          controller: _range,
          suffix: 'km',
          hint: 'From the brochure',
          error: _range.text.isNotEmpty && _rangeValue == null ? 'Enter 50 to 1500' : null,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Drag coefficient (Cd)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _NumberField(
          fieldKey: const Key('dragField'),
          controller: _drag,
          helper: 'VF 7: 0.29',
          error: _dragValue == null ? 'Enter 0.15 to 0.6' : null,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Fastest DC charging the car takes (optional)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _NumberField(
          fieldKey: const Key('maxChargeField'),
          controller: _maxCharge,
          suffix: 'kW',
          helper: 'Blank assumes ${EnergyModel.defaultMaxChargeKw.round()} kW, about right for a VF 6 or VF 7',
          error: _maxChargeValid ? null : 'Enter 10 to 500, or leave blank',
          onChanged: () => setState(() {}),
        ),
      ];
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    this.suffix,
    this.hint,
    this.helper,
    this.error,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String? suffix;
  final String? hint;
  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          suffixText: suffix,
          hintText: hint,
          helperText: helper,
          border: const OutlineInputBorder(),
          errorText: error,
        ),
        onChanged: (_) => onChanged(),
      );
}

class _QuickOptions extends StatelessWidget {
  const _QuickOptions({required this.options, required this.current, required this.onSelected});

  final Map<String, double> options;
  final double? current;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in options.entries)
          ChoiceChip(
            label: Text(entry.key),
            labelPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            selected: current == entry.value,
            onSelected: (_) => onSelected(entry.value),
          ),
      ],
    );
  }
}

class _MissingKeyBanner extends StatelessWidget {
  const _MissingKeyBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'This build has no Google API key, so search and navigation will not work. '
        'Add config/keys.json and rebuild (see README).',
        style: TextStyle(color: colors.onErrorContainer),
      ),
    );
  }
}
