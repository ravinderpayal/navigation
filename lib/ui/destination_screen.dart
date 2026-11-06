import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../config.dart';
import '../core/energy.dart';
import '../core/geo.dart';
import '../data/google_api.dart';
import 'navigation_screen.dart';

class DestinationScreen extends StatefulWidget {
  const DestinationScreen({super.key, required this.startSoc, required this.energy});

  final double startSoc;
  final EnergyModel energy;

  @override
  State<DestinationScreen> createState() => _DestinationScreenState();
}

class _DestinationScreenState extends State<DestinationScreen> {
  static const _debounce = Duration(milliseconds: 300);
  static const _minChars = 2;

  final _api = GoogleApi(apiKey: AppConfig.googleApiKey, baseOverride: AppConfig.apiBaseOverride);
  final _query = TextEditingController();
  Timer? _timer;
  int _searchNumber = 0;
  String _sessionToken = _newSessionToken();
  GeoPoint? _here;
  List<PlaceSuggestion> _suggestions = const [];
  String? _error;
  bool _searching = false;
  bool _opening = false;

  static String _newSessionToken() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<GeoPoint?> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setError('Location is switched off. Turn it on to navigate.');
        return null;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _setError('Location permission is needed to navigate. Allow it in Settings.');
        return null;
      }
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _here = GeoPoint(last.latitude, last.longitude);
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(timeLimit: Duration(seconds: 15)),
      );
      _here = GeoPoint(position.latitude, position.longitude);
    } catch (_) {
      // Fall through to the last known position, if there was one.
    }
    if (mounted) setState(() {});
    return _here;
  }

  void _setError(String message) {
    if (mounted) setState(() => _error = message);
  }

  void _onChanged(String text) {
    _timer?.cancel();
    final query = text.trim();
    if (query.length < _minChars) {
      _searchNumber++;
      setState(() {
        _suggestions = const [];
        _searching = false;
        _error = null;
      });
      return;
    }
    setState(() => _searching = true);
    _timer = Timer(_debounce, () => _search(query));
  }

  Future<void> _search(String query) async {
    final number = ++_searchNumber;
    try {
      final results = await _api.autocomplete(query, sessionToken: _sessionToken, near: _here);
      if (!mounted || number != _searchNumber) return;
      setState(() {
        _suggestions = results;
        _searching = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || number != _searchNumber) return;
      setState(() {
        _searching = false;
        _error = 'Could not search: $e';
      });
    }
  }

  Future<void> _select(PlaceSuggestion suggestion) async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final here = _here ?? await _locate();
      if (here == null) {
        _error ??= 'Waiting for your location. Try again in a moment.';
        return;
      }
      final place = await _api.placeDetails(suggestion.placeId, sessionToken: _sessionToken);
      _sessionToken = _newSessionToken(); // Selecting a place ends the billing session.
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => NavigationScreen(
          api: _api,
          startSoc: widget.startSoc,
          energy: widget.energy,
          origin: here,
          destination: place,
        ),
      ));
    } catch (e) {
      _error = 'Could not open that place: $e';
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Where to?')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                key: const Key('destinationField'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: Theme.of(context).textTheme.titleLarge,
                decoration: InputDecoration(
                  hintText: 'Search for a place',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _onChanged,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            if (_opening) const LinearProgressIndicator(),
            Expanded(
              child: ListView.separated(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final s = _suggestions[index];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    minVerticalPadding: 14,
                    title: Text(s.title),
                    subtitle: s.subtitle.isEmpty ? null : Text(s.subtitle),
                    enabled: !_opening,
                    onTap: () => _select(s),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
