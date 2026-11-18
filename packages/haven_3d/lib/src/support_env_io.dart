import 'dart:io';

/// `flutter test` setzt diese Variable.
final bool isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
