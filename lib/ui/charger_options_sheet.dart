import 'package:flutter/material.dart';

import '../core/charger_options.dart';

/// The ranked list of chargers on the route.
class ChargerOptionsSheet extends StatefulWidget {
  const ChargerOptionsSheet({
    super.key,
    required this.load,
    required this.onSelected,
    required this.wantFood,
    required this.onWantFoodChanged,
    this.outlook,
  });

  /// Loads the list, scoring restaurants only when food is wanted.
  final Stream<ChargerOptions> Function(bool wantFood) load;
  final ValueChanged<ChargerSite> onSelected;
  final bool wantFood;

  /// Called to remember the choice for next time.
  final ValueChanged<bool> onWantFoodChanged;

  /// Where the battery is heading, in a sentence. Reread as results arrive.
  final String Function()? outlook;

  @override
  State<ChargerOptionsSheet> createState() => _ChargerOptionsSheetState();
}

class _ChargerOptionsSheetState extends State<ChargerOptionsSheet> {
  late bool _wantFood = widget.wantFood;
  late Stream<ChargerOptions> _options = widget.load(_wantFood);

  void _setWantFood(bool value) {
    widget.onWantFoodChanged(value);
    setState(() {
      _wantFood = value;
      _options = widget.load(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outlook = widget.outlook;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: SafeArea(
        child: StreamBuilder<ChargerOptions>(
          stream: _options,
          builder: (context, snapshot) {
            final data = snapshot.data;
            final sites = data?.sites ?? const <ChargerSite>[];
            final loading = !(data?.done ?? false) && !snapshot.hasError;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text('Chargers on your route', style: theme.textTheme.titleLarge),
                ),
                if (outlook != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(outlook(), key: const Key('batteryOutlook')),
                  ),
                SwitchListTile(
                  key: const Key('wantFoodSwitch'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  secondary: const Icon(Icons.restaurant),
                  title: const Text('Good food nearby'),
                  subtitle: Text(_wantFood
                      ? 'Chargers near a highly rated restaurant rank higher'
                      : 'Restaurants are ignored'),
                  value: _wantFood,
                  onChanged: _setWantFood,
                ),
                SizedBox(height: 4, child: loading ? const LinearProgressIndicator() : null),
                Expanded(
                  child: sites.isEmpty && !loading
                      ? const Center(child: Text('No reachable chargers on this route.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: sites.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) => _SiteCard(
                            key: ValueKey(sites[index].primary.charger.id),
                            site: sites[index],
                            onGo: () => widget.onSelected(sites[index]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({super.key, required this.site, required this.onGo});

  /// Under this the charge estimate is too thin to count on.
  static const _lowArrivalSoc = 18.0;

  final ChargerSite site;
  final VoidCallback onGo;

  String get _guns {
    final total = '${site.totalGuns} ${site.totalGuns == 1 ? 'gun' : 'guns'}';
    if (site.allGunsKnown) return '${site.freeGuns} of $total free';
    return site.freeGuns > 0 ? 'At least ${site.freeGuns} of $total free' : total;
  }

  String get _status => switch (site.status) {
        SiteStatus.available => 'Available',
        SiteStatus.busy => 'In use now',
        SiteStatus.notChecked => 'Status not checked',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final name = site.primary.charger.name;
    final minutes = site.chargeMinutes;
    final details = [
      site.kw > 0 ? '${site.kw.round()} kW' : 'Power not listed',
      site.isFree ? 'Free' : 'Paid',
      _status,
      _guns,
    ].join(' · ');
    final restaurant = site.restaurant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    site.otherChargers == 0 ? name : '$name + ${site.otherChargers} more here',
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(site.score.toStringAsFixed(2), style: theme.textTheme.labelLarge),
              ],
            ),
            if (site.isSuggested)
              Text('Suggested stop', style: theme.textTheme.labelMedium?.copyWith(color: colors.primary)),
            const SizedBox(height: 4),
            Text(details),
            const SizedBox(height: 2),
            Text.rich(TextSpan(children: [
              TextSpan(
                text: 'Arrive ~${site.arrivalSoc.round()}%',
                style: site.arrivalSoc < _lowArrivalSoc
                    ? TextStyle(color: colors.error, fontWeight: FontWeight.w600)
                    : null,
              ),
              TextSpan(text: minutes == null ? '' : ' · about $minutes min to 80%'),
              if (site.primary.detourKm >= 1)
                TextSpan(text: ' · ${site.primary.detourKm.round()} km detour'),
            ])),
            if (site.healthNote != null) ...[
              const SizedBox(height: 2),
              Text(site.healthNote!, style: theme.textTheme.bodySmall),
            ],
            if (restaurant != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.restaurant, size: 18, color: colors.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${restaurant.name} · ${restaurant.rating.toStringAsFixed(1)} ★',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.tertiary),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                onPressed: onGo,
                child: const Text('Go here'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
