import 'package:material_ui/material_ui.dart';

/// HA-Wetterzustand auf Deutsch.
String weatherLabel(String condition) => switch (condition) {
  'clear-night' => 'klar',
  'cloudy' => 'bewölkt',
  'exceptional' => 'außergewöhnlich',
  'fog' => 'Nebel',
  'hail' => 'Hagel',
  'lightning' => 'Gewitter',
  'lightning-rainy' => 'Gewitter mit Regen',
  'partlycloudy' => 'teils bewölkt',
  'pouring' => 'Starkregen',
  'rainy' => 'Regen',
  'snowy' => 'Schnee',
  'snowy-rainy' => 'Schneeregen',
  'sunny' => 'sonnig',
  'windy' || 'windy-variant' => 'windig',
  _ => condition,
};

IconData weatherIcon(String condition) => switch (condition) {
  'clear-night' => Icons.nightlight_round,
  'sunny' => Icons.wb_sunny_rounded,
  'partlycloudy' => Icons.wb_cloudy_rounded,
  'rainy' || 'pouring' => Icons.water_drop_rounded,
  'snowy' || 'snowy-rainy' || 'hail' => Icons.ac_unit_rounded,
  'lightning' || 'lightning-rainy' => Icons.bolt_rounded,
  'fog' => Icons.cloud_queue_rounded,
  'windy' || 'windy-variant' => Icons.air_rounded,
  _ => Icons.cloud_rounded,
};

/// Zahl mit Komma, eine Nachkommastelle.
String num1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
