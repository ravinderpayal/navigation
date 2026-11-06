import 'dart:math' as math;

/// How the car's rated range was measured.
enum RangeRating {
  /// India's MIDC lab cycle: gentle, mostly city-speed driving.
  arai,

  /// The US label figure: city and highway mixed, already adjusted to real use.
  epa,
}

/// The air the car pushes through.
class AirConditions {
  const AirConditions({
    required this.densityKgM3,
    this.windKmh = 0,
    this.windFromDegrees = 0,
    this.temperatureC,
  });

  /// From what weather services report. Humid air is lighter than dry air.
  factory AirConditions.fromWeather({
    required double temperatureC,
    required double relativeHumidity,
    required double pressureHpa,
    double windKmh = 0,
    double windFromDegrees = 0,
  }) {
    final kelvin = temperatureC + 273.15;
    final saturationHpa = 6.1078 * math.pow(10, 7.5 * temperatureC / (temperatureC + 237.3));
    final vapourPa = relativeHumidity.clamp(0, 100) / 100 * saturationHpa * 100;
    final dryPa = pressureHpa * 100 - vapourPa;
    return AirConditions(
      densityKgM3: dryPa / (287.058 * kelvin) + vapourPa / (461.495 * kelvin),
      windKmh: windKmh,
      windFromDegrees: windFromDegrees,
      temperatureC: temperatureC,
    );
  }

  /// 20 °C at sea level on a still day.
  static const standard = AirConditions(densityKgM3: EnergyModel.referenceAirDensity);

  /// Weather services report wind 10 m up. Near the road it's slower.
  static const _carHeightWindShare = 0.7;

  final double densityKgM3;
  final double windKmh;

  /// Where the wind blows from, clockwise from north.
  final double windFromDegrees;
  final double? temperatureC;

  /// Wind against the car when heading [headingDegrees]. Negative is a tailwind.
  double headwindKmh(double headingDegrees) =>
      windKmh * _carHeightWindShare * math.cos((windFromDegrees - headingDegrees) * math.pi / 180);
}

/// Battery use for one car, from what the driver knows about it.
///
/// Consumption has four parts. Air drag grows with the square of the air speed,
/// and uses the drag coefficient and the air's density. Accessories like the air
/// conditioner cost the same per hour, so more per km when slow. Rolling
/// resistance and drivetrain losses are about the same per km at any speed. In
/// towns and traffic, each stop throws away some of the energy it took to get
/// up to speed, even with regenerative braking.
/// The 80 km/h figure fixes the total, and the rated range, adjusted to what
/// drivers really get, fixes the split between accessories and the rest.
class EnergyModel {
  const EnergyModel({
    required this.kwhPer100Km,
    required this.batteryKwh,
    this.dragCd = defaultDragCd,
    this.ratedRangeKm,
    this.rating = RangeRating.arai,
    this.maxChargeKw,
    this.burnScale = 1,
    this.cruiseKmh,
  });

  static const referenceKmh = 80.0;

  /// The driver's 80 km/h figure is taken as being on a still, mild day.
  static const referenceAirDensity = 1.2;
  static const defaultDragCd = 0.29;

  /// Assumed for every car: about right for a compact SUV like the VF 6 or VF 7.
  static const frontalAreaM2 = 2.6;

  /// Share of battery energy that reaches the wheels.
  static const drivetrainEfficiency = 0.9;

  /// Average speed of each rating's test, which is where its figure applies.
  static const _ratingKmh = {RangeRating.arai: 34.0, RangeRating.epa: 48.0};

  /// Share of the rated range drivers really get. ARAI's lab test runs without
  /// air conditioning and very gently; owners in India typically see about three
  /// quarters of it. EPA's label figure is already adjusted to real driving.
  static const _realWorldShare = {RangeRating.arai: 0.75, RangeRating.epa: 1.0};

  /// Car and two people, for the energy it takes to get up to speed. A VF 7
  /// weighs about 1.9 t empty; assumed for every car.
  static const massKg = 2100.0;

  /// Share of the energy in slowing down that regenerative braking recovers.
  static const regenShare = 0.6;

  /// Typical town driving: this many stops per km, each from this speed.
  static const _townStopsPerKm = 1.5;
  static const _townStopFromKmh = 35.0;

  /// Used when no rated range is given: fans, screens and a little cooling.
  static const _defaultAccessoryKw = 1.0;
  static const _minAccessoryKw = 0.3;
  static const _maxAccessoryKw = 3.0;

  /// When the driver leaves the car's peak charging power blank. With
  /// [chargeCurve], this gives about 24 min for 10-70% on a 70.8 kWh pack, as
  /// VinFast quotes for the VF 6 and VF 7.
  static const defaultMaxChargeKw = 110.0;

  /// Chargers seldom deliver all of their rating: shared cabinets, hot cables.
  static const chargerShare = 0.9;

  /// Charging time is added up in steps this big, in % of battery.
  static const _chargeStepSoc = 0.5;

  /// Rolling resistance alone costs at least this, in kWh per 100 km.
  static const _minRollingKwhPer100 = 3.0;

  /// Accessories per km stop making sense when the car barely moves.
  static const _minKmh = 5.0;

  /// The driver's consumption at a steady 80 km/h, in kWh per 100 km.
  final double kwhPer100Km;
  final double batteryKwh;
  final double dragCd;

  /// The car's official range on a full battery, if the driver gave one.
  final double? ratedRangeKm;
  final RangeRating rating;

  /// The most the car itself accepts from a DC charger, at its best. Null
  /// assumes [defaultMaxChargeKw].
  final double? maxChargeKw;

  /// Highest speed planned for, when the driver is advised to cruise slower than
  /// the road allows. Null plans for the road's own speed.
  final double? cruiseKmh;

  /// How driving lately compares with what the route predicted. Above 1, the
  /// battery has been going faster than expected, and predictions use that.
  final double burnScale;

  double get socPerKm => kwhPer100Km * burnScale / batteryKwh;

  EnergyModel withBurnScale(double scale) => _copy(burnScale: scale, cruiseKmh: cruiseKmh);

  EnergyModel withCruise(double? kmh) => _copy(burnScale: burnScale, cruiseKmh: kmh);

  EnergyModel _copy({required double burnScale, required double? cruiseKmh}) => EnergyModel(
        kwhPer100Km: kwhPer100Km,
        batteryKwh: batteryKwh,
        dragCd: dragCd,
        ratedRangeKm: ratedRangeKm,
        rating: rating,
        maxChargeKw: maxChargeKw,
        burnScale: burnScale,
        cruiseKmh: cruiseKmh,
      );

  /// What a consumption curve depends on, for caching per route.
  Object get curveKey => (kwhPer100Km, batteryKwh, dragCd, ratedRangeKm, rating, cruiseKmh);

  /// Air drag in kWh per 100 km, at the battery.
  double _dragKwhPer100(double kmh, double density, double headwindKmh) {
    final airMs = math.max(0.0, kmh + headwindKmh) / 3.6;
    final newtons = 0.5 * density * dragCd * frontalAreaM2 * airMs * airMs;
    return newtons * 100000 / 3600000 / drivetrainEfficiency;
  }

  double _accessoryKwhPer100(double kw, double kmh) => kw * 100 / math.max(kmh, _minKmh);

  /// Energy, in kWh, to change speed. Speeding up draws it through the
  /// drivetrain; slowing down wins back what regenerative braking can.
  double kineticKwh(double fromKmh, double toKmh) {
    final from = fromKmh / 3.6, to = toKmh / 3.6;
    final joules = 0.5 * massKg * (to * to - from * from);
    return (joules > 0 ? joules / drivetrainEfficiency : joules * regenShare) / 3600000;
  }

  /// What stop-start town driving costs on top of steady driving, per 100 km.
  double get stopStartKwhPer100 =>
      _townStopsPerKm * 100 * (kineticKwh(0, _townStopFromKmh) + kineticKwh(_townStopFromKmh, 0));

  /// Solved from the rated range as drivers really get it, so the curve passes
  /// through both figures. Both rating tests include stops.
  double get accessoryKw {
    final range = ratedRangeKm;
    if (range == null || range <= 0) return _defaultAccessoryKw;
    final testKmh = _ratingKmh[rating]!;
    final testKwhPer100 = batteryKwh / (range * _realWorldShare[rating]!) * 100;
    final kw = (testKwhPer100 -
            stopStartKwhPer100 -
            kwhPer100Km -
            _dragKwhPer100(testKmh, referenceAirDensity, 0) +
            _dragKwhPer100(referenceKmh, referenceAirDensity, 0)) /
        (100 / testKmh - 100 / referenceKmh);
    return kw.clamp(_minAccessoryKw, _maxAccessoryKw);
  }

  double get _rollingKwhPer100 => math.max(
      _minRollingKwhPer100,
      kwhPer100Km -
          _dragKwhPer100(referenceKmh, referenceAirDensity, 0) -
          _accessoryKwhPer100(accessoryKw, referenceKmh));

  /// Consumption at a speed, in kWh per 100 km. [stopStart] adds the stops of
  /// town driving or traffic.
  double kwhPer100At(double kmh, {AirConditions? air, double headwindKmh = 0, bool stopStart = false}) =>
      _rollingKwhPer100 +
      _dragKwhPer100(kmh, air?.densityKgM3 ?? referenceAirDensity, headwindKmh) +
      _accessoryKwhPer100(accessoryKw, kmh) +
      (stopStart ? stopStartKwhPer100 : 0);

  /// Consumption compared with the 80 km/h figure: 1 means the same.
  double factorAt(double kmh, {AirConditions? air, double headwindKmh = 0, bool stopStart = false}) =>
      kwhPer100At(kmh, air: air, headwindKmh: headwindKmh, stopStart: stopStart) / kwhPer100At(referenceKmh);

  double get peakChargeKw {
    final carMax = maxChargeKw;
    return carMax == null || carMax <= 0 ? defaultMaxChargeKw : carMax;
  }

  /// Share of its peak charging power a typical lithium-ion car accepts at a
  /// charge level: all of it to about half, easing to 75%, then crawling.
  static double chargeCurve(double soc) {
    if (soc < 50) return 1;
    if (soc < 75) return 1 - 0.35 * (soc - 50) / 25;
    if (soc < 80) return 0.65 - 0.2 * (soc - 75) / 5;
    if (soc < 90) return 0.45 - 0.15 * (soc - 80) / 10;
    return math.max(0.05, 0.3 - 0.18 * (soc - 90) / 10);
  }

  /// Power going in at [soc]: whichever is lower, the charger or the car.
  double chargeKwAt(double soc, double chargerKw) =>
      math.min(chargerKw * chargerShare, peakChargeKw * chargeCurve(soc));

  /// Minutes to charge from one level to another on a charger of [chargerKw].
  double chargeMinutes(double fromSoc, double toSoc, double chargerKw) {
    var minutes = 0.0;
    for (var soc = fromSoc; soc < toSoc; soc += _chargeStepSoc) {
      final step = math.min(_chargeStepSoc, toSoc - soc);
      minutes += step / 100 * batteryKwh / chargeKwAt(soc + step / 2, chargerKw) * 60;
    }
    return minutes;
  }

  /// The level reached after charging for [minutes], never above [maxSoc].
  double socAfterCharging(double fromSoc, double minutes, double chargerKw, {double maxSoc = 100}) {
    var soc = fromSoc, left = minutes;
    while (soc < maxSoc && left > 0) {
      final step = math.min(_chargeStepSoc, maxSoc - soc);
      final stepMinutes = step / 100 * batteryKwh / chargeKwAt(soc + step / 2, chargerKw) * 60;
      if (stepMinutes > left) return soc + step * left / stepMinutes;
      soc += step;
      left -= stepMinutes;
    }
    return soc;
  }
}

/// Guesses the current state of charge from distance driven since the last
/// known reading. Pure dead reckoning: the app has no link to the car.
class SocEstimator {
  SocEstimator({required double startSoc, required this.energy}) : _baseSoc = startSoc;

  final EnergyModel energy;
  double _baseSoc;
  double _kmSinceBase = 0;

  double get soc => (_baseSoc - _kmSinceBase * energy.socPerKm).clamp(0.0, 100.0);

  /// [km] is in 80 km/h km: a km that cost twice the 80 km/h figure counts as 2.
  void addDistance(double km) {
    if (km > 0) _kmSinceBase += km;
  }

  /// A fresh reading from the driver, for example after charging.
  void reset(double soc) {
    _baseSoc = soc;
    _kmSinceBase = 0;
  }
}

/// What kind of road a stretch is, judged by how fast traffic flows on it freely.
/// Google doesn't report road type or surface, but both show up in this speed.
enum RoadKind { city, highway, expressway }

RoadKind roadKindFor(double freeFlowKmh) => freeFlowKmh >= 85
    ? RoadKind.expressway
    : (freeFlowKmh >= 50 ? RoadKind.highway : RoadKind.city);
