# Vinfast Copilot

A Flutter navigation app for VinFast EVs in India. It estimates battery charge from distance driven and plans charging stops around the free charger list.

## Setup

1. In Google Cloud, create an API key on a project with billing. Enable **Navigation SDK**, **Maps SDK for Android**, **Maps SDK for iOS**, **Places API (New)** and **Routes API**.
2. Copy `config/keys.example.json` to `config/keys.json` and put the key in it. The file is gitignored.
3. Run:

```sh
flutter run --dart-define-from-file=config/keys.json
```

Android builds need a JDK. If `java` isn't on your path:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
```

Keep the key restricted by API only. Places and Routes are called over REST from the app, so an Android-app or iOS-app restriction on the key will make those calls fail.

## Test a drive without driving

Add `--dart-define=SIMULATE_DRIVE=true`. The Navigation SDK then drives the route at 5x speed, so the estimate falls and chargers appear. `--dart-define=SIMULATION_SPEED=1` drives it at real speed instead, which suits screenshots.

## Your car

The app asks for the charge at every start. The car's details are remembered after the first time, under "Your car":

- Consumption at a steady 80 km/h, in kWh per 100 km.
- Battery size.
- Rated range, ARAI or EPA.
- Drag coefficient. The VF 7 is 0.29.
- Optionally, the car's peak DC charging power. Blank assumes 110 kW, which with the curve below matches VinFast's quoted 10–70% in about 25 minutes.

These build a consumption curve in `EnergyModel` (`lib/core/energy.dart`):

- **Air drag** uses the drag coefficient, an assumed 2.6 m² frontal area and the air's density, and grows with the square of the air speed.
- **Accessories** such as the air conditioner cost the same per hour, so more per km when slow.
- **Stop-start losses** apply on town roads and in traffic: 1.5 stops per km from 35 km/h, for an assumed 2.1 t car with 60% regenerative braking, about 2 kWh/100 km.
- **Everything else** costs the same per km.

The 80 km/h figure sets the total. The rated range sets how much goes to accessories, taken at its test's average speed (34 km/h for ARAI, 48 km/h for EPA). ARAI's lab test runs without AC and very gently, so only 75% of an ARAI range is counted. EPA's label is already real-world, so it's counted in full.

For a VF 7 at 16 kWh/100 km and 532 km ARAI, that gives about 18.4 kWh/100 km in town at 30 km/h, 15.4 at a steady 75, 19.1 at 100 and 24 at 120. A 154 km trip with 40 km of town and the rest highway uses about 35% at Google's speeds, or 41% cruising at 100.

Weather comes from [Open-Meteo](https://open-meteo.com) every 25 km along the route when the trip is planned, and again every 30 minutes. Temperature, pressure and humidity give the air density. Wind against the car's direction counts at 70% of its 10 m speed. Open-Meteo's free tier is for non-commercial use only.

While driving, the app meters the battery from what the car actually does:

- **Distance** is costed at the GPS speed, in the weather there.
- **Speed changes** of 5 km/h or more add the energy to speed up, and take off what braking wins back.
- **Standing still** for more than 15 seconds during guidance adds the AC and screens' power for that time.

The battery bubble shows the average kWh/100 km over the last 2 km. When driving uses more than the route predicted, later predictions are scaled to match. This is weighted to the last 10–15 km and limited to between 0.8 and 1.5 times. Every arrival charge on the cards (the stop card, the plan, the "Going to" card and the destination) is worked out again from the charge now and this rate. If the next stop would be reached below 20%, the trip replans, at most every 2 minutes.

## How it decides

All the numbers are in `PlannerRules` in `lib/core/charge_planner.dart`.

| Rule | Value |
| --- | --- |
| Show chargers on the map | Estimate below 50% |
| Target arrival charge at a stop | 25% |
| Charge at the destination | 55% on trips of 100 km or more, so there's no hunt for a charger in city traffic on arrival. 25% on shorter trips |
| Never plan to arrive below | 20%. If nothing above 20% is reachable, the nearest charger is planned and flagged as below the safe level |
| Free charger detour limit, open road | 15 km extra in total, there and back |
| Free charger detour limit, city or congestion | 6 km extra in total |
| Counts as city | Under 45 km/h free-flow on that route step, or Google reports slow traffic |
| Minimum charger power for a route stop | 20 kW DC |
| Charge to | 80%, or less if the rest of the trip needs less |
| Fast charger first | 180 kW or more, a free gun confirmed, at most 3 km extra by road, and reachable above 20% at the current rate of use |
| Quick top-up | When the destination is just short of 25%, a 5–10 minute stop at a 60 kW or faster charger near halfway, for 20 km or what's needed, whichever is more |

A free charger reached with between 55% and 20% left beats a paid one, and between 45% and 20% is preferred. An available 180 kW charger on the road beats both. Google, the status feed and Statiq checks can confirm a free gun. Chargers of 180 kW or more on the road are always shown on the map as purple "180+" pins.

Paid chargers come from Google Places and are used only when no free charger fits. All detours are checked against real roads before a stop is chosen.

## Live charger status

Free chargers are checked against `chargeindia.com/api/stations`. The station list is downloaded when a route is planned, and every 10 minutes while chargers are showing. A charger is matched to a station when the coordinates are within 3 m, or within 300 m with a similar name.

| Feed says | What the app does |
| --- | --- |
| Available | Preferred, shown as available |
| Not in the feed, or the feed is down or over 30 minutes old | Still used, shown as "Status not checked" |
| Reported down, then `In use` on checking | Only suggested if at least 15 minutes away, and not shown as a map pin |
| Reported down, then `Out of service`, `Coming soon`, `Status unknown` or `Blocked` | Never shown or suggested |

The feed covers only part of the free charger list, so most chargers are "Status not checked". The planner checks a station individually just before suggesting it, and only judges its CCS2 DC connectors.

## Statiq and the 30% forecast

The Statiq station map (`/station/v1/markers`) loads once per trip in the background, for a box around the route, filtered to CCS2. Stations within 6 km of the route are kept.

During a trip the app forecasts where the battery reaches 30%. Road type comes from Google's free-flow speed on each step, congestion from its traffic data, and times are scaled to Google's predicted arrival and navigation's live estimate. `energyFactorForSpeed` in `lib/core/energy.dart` holds the assumed consumption by speed, and these are estimates to tune against real driving.

Stations within 20 km of that point (or the nearest 5 on a bare stretch, up to 30) are checked every 3 minutes through `/station/v1/details`, and the results feed the planner, map pins and picker. `is_connected: false` counts as dead whatever the connectors report, and `error_message` is ignored because it often says "Faulted" on working connectors.

Records from different sources are merged by location and name, at most once per record. Records with their own ids in one source stay separate chargers, and their guns add up when shown as one stop.

## Screen layout and ending navigation

The map takes the top of the screen and the cards sit below it, so nothing covers the map or the turn card, speedometer and ETA bar that navigation draws on it. The map shrinks as cards appear, and in the preview the route is fitted again whenever the map changes size.

During guidance the round ✕ button bottom-left, or the back gesture, ends navigation after a confirmation. Guidance stops and the screen goes back to the route preview, where Start begins again and Back leaves. Stopping navigation from the Android Auto screen does the same. Ending closes the navigation session with `GoogleMapsNavigator.cleanup()`, because on Android clearing destinations alone often leaves the old route drawn. Start opens a new session.

## Heading to a charger

Once the driver taps Go, the card shows the estimated charge on arrival, red when under 20%. It also shows the total stop time: charging to 80%, plus 8 minutes to park (3), connect (2) and leave (3). Both figures update as the car drives. The overhead is `stopOverheadMinutes` in `PlannerRules`.

## Charging time

Charging follows a typical lithium-ion curve (`EnergyModel.chargeCurve`). The car takes its full peak power up to about 50%, eases to 65% of peak by 75%, 45% by 80%, 30% by 90%, and crawls after that. A charger gives 90% of its rating at most. At any level the slower of the two decides. For a VF 7, that's about 25 minutes for 10–70% on a fast charger, 10 for 80–90% and 20 for 90–100%. On a 30 kW charger, 20–80% takes about 94 minutes.

When choosing between chargers, the minutes a slow charger loses against a fast one count like extra km, at 1.5 km per minute. A 60 kW charger is worth stopping about 70 km further from the ideal spot than a 30 kW one, within the reachable range. Free chargers still come before paid ones.

## Cruising speed

Air drag grows with the square of speed, so each extra km/h costs more battery than the last. That battery has to be charged back, slowly once past 75%. `CruiseAdvisor` (`lib/core/cruise_speed.dart`) tries 70 to 120 km/h for the whole trip. For each speed it adds the driving time to the charging time needed to arrive with 55%, at the power of the planned stops (60 kW if there are none). Each stop is counted from 25% to at most 80%, plus 8 minutes. It suggests the speed with the shortest total, and within a minute the slower speed wins.

The cruising speed only applies on open road: up to 120 km/h on expressways and 100 on highways, judged by Google's free-flow speed and limited to roads without congestion. Towns and traffic keep Google's speed. Google's own typical speed on the Delhi–Mumbai Expressway is under 90, well below what drivers choose, so the plan uses the suggested speed there instead.

The suggestion shows on the preview and in the battery bubble, turning red when the car goes more than 5 km/h faster. Driving at a different speed changes the burn rate, and predictions follow.

## Alerts

During guidance the phone chimes and vibrates before the turn-off for the suggested or chosen charger: once about 90 seconds ahead (at least 1 km), and urgently about 30 seconds ahead (at least 300 m), using the current speed. It does the same near 22% and below 20%. The message also shows on the phone and the car screen. The chime plays as navigation audio on Android. On iPhone it's an alert sound, so the silent switch mutes it, but the phone still vibrates.

## Charger picker

The Chargers button above the battery bubble lists up to 12 reachable stops, best first. Chargers within 150 m are merged into one stop. The weights are in `RankingRules` in `lib/core/charger_options.dart`.

| Factor | Points |
| --- | --- |
| Free | +0.4 |
| Status not checked | -0.5 |
| Highly rated restaurant within 500 m (4.2+ stars, 100+ reviews) | +0.35 |
| 100 kW or more | +0.4 |
| 60 to 99 kW | +0.2 |
| Under 60 kW | 0 |

An available charger of 180 kW or more on the road is listed first, whatever its score.

The "Good food nearby" switch at the top of the list turns the restaurant points on or off. When it's off, restaurants aren't looked up, which also saves the Places requests. The choice is remembered between trips, and it's on by default.

Equal scores go to a stop with a free gun, then to the one closest to 25% on arrival. Charge times follow the charging curve, up to 80%. Detours are checked against real roads, and stops over the detour limits are dropped.

The first opening on a route can use up to 24 Routes API, 12 Places Nearby and 1 Places Text Search requests, plus requests to the status servers. Google results are kept for the trip.

## Charger data

`assets/free_chargers.json` is generated from the CSV. After updating the CSV, run:

```sh
python3 tool/build_chargers.py
```

It removes test sites and locations with unusable coordinates, and merges connectors into one record per location.

## Android Auto

The app registers as a navigation app, and the car screen shows the map, turn card and charger pins. Start a trip on the phone first.

To test, install the [Desktop Head Unit](https://developer.android.com/training/cars/testing/dhu) and run a debug build. Publishing on Google Play needs Google's review of the navigation category.

## CarPlay

The CarPlay scene is in `ios/Runner/CarSceneDelegate.swift`. The `com.apple.developer.carplay-maps` entitlement is applied to simulator builds only, because device builds can't be signed with it until Apple approves your account.

After Apple grants the entitlement, set `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` for all SDKs on the Runner target. To test in the simulator, use I/O > External Displays > CarPlay.

## Checking a real trip

`tool/check_trip_plan.dart` plans Delhi to Jaipur with the real route, chargers, weather and status sources. It reads the key from `config/keys.json`:

```sh
dart run tool/check_trip_plan.dart 80 16 532
```

The arguments are starting charge, kWh/100 km at 80 km/h, and rated range.

## Tests

```sh
flutter test
```

`tool/fake_google.py` stands in for Places, Routes and the status feed when no key is available:

```sh
python3 tool/fake_google.py
flutter run --dart-define=MAPS_API_KEY=fake --dart-define=API_BASE_OVERRIDE=http://10.0.2.2:8787
```

The map and guidance can't run this way, because the Navigation SDK needs a real key.
