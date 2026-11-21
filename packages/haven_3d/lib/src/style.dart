import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'model.dart';

/// Aussehen der 3D-Ansicht. Die App setzt es später aus ihrem Theme
/// (`HavenColors`), die Demo nutzt [SceneStyle.light] und [SceneStyle.dark].
///
/// Der Hintergrund ist immer durchsichtig: Was hinter dem Widget liegt
/// (Verlauf, Karte), scheint um die Wohnung herum und durch halb
/// durchsichtige Wände und Böden durch.
@immutable
class SceneStyle {
  const SceneStyle({
    required this.ink,
    required this.surface,
    required this.soft,
    required this.floor,
    required this.wall,
    required this.accent,
    this.glass = const Color(0xFF9CC8F0),
    this.dark = const Color(0xFF8C9199),
    this.green = const Color(0xFF6BA36B),
    this.edgeWidth = 2.5,
    this.edgeWorldWidth = 0.023,
    this.roomGap = 0.16,
    this.roomRadius = 0.25,
    this.wallOpacity = 0.45,
    this.floorOpacity = 0.92,
    this.cutaway = true,
    this.ambient = 1.0,
    this.sun = 1.0,
    this.shadows = true,
    this.lampGlow = 1.0,
    this.edgesOnlyFromAbove = true,
    this.roomEdgeOpacity = 1,
    this.shadowFill = 0.3,
    this.wallGlow = 0,
    this.skyMinAmbient = 0.42,
    this.paintScale = 1,
  });

  /// Hell: fast weiße Möbel auf warmem Grau, wie die Haven-Karte am Tag.
  factory SceneStyle.light() => const SceneStyle(
    ink: Color(0xFF5E636B),
    // Wie die 2D-Karte: heller Boden, Möbel einen Ton dunkler.
    surface: Color(0xFFE3E1DC),
    soft: Color(0xFFDDDAD3),
    floor: Color(0xFFF3F2EE),
    // Wände hell, etwas deckender und leicht selbst leuchtend: auch vor
    // dem Himmel und bei trübem Wetter nicht grau.
    wall: Color(0xFFF1EFEB),
    wallOpacity: 0.55,
    wallGlow: 0.22,
    // Raumumrisse leise, die Möbelkanten tragen die Zeichnung.
    roomEdgeOpacity: 0.38,
    accent: Color(0xFF2F7DF6),
    // Lampen kräftig genug, dass ein beleuchteter Raum (mit Raumlicht)
    // auch am Tag sichtbar warm wird.
    lampGlow: 1.15,
    // Ohne Linien beim Kippen trägt die Schattierung die Form; genug
    // Umgebungslicht, dass nichts grau und schwer wirkt.
    ambient: 0.8,
    sun: 1.25,
  );

  /// Abend ohne Himmel (dunkles Design ohne Umgebung): dieselben Farben
  /// wie [SceneStyle.light] (wie mit Himmel bei Nacht), nur das feste Licht
  /// gedämpft, und Linien hell wie im dunklen Stil. So ändert das Ausschalten
  /// der Umgebung Licht und Hintergrund, nicht die Farben der Dinge.
  factory SceneStyle.evening() {
    final l = SceneStyle.light();
    final d = SceneStyle.dark();
    return l.copyWith(
      ink: d.ink,
      roomEdgeOpacity: d.roomEdgeOpacity,
      // Hell genug, dass auch dunkle Räume lesbar bleiben; beleuchtete
      // Räume heben sich über ihr Raumlicht ab, nicht über Finsternis.
      ambient: 0.45,
      sun: 0.3,
      lampGlow: 1.3,
      shadowFill: 0.55,
      // Kein Eigenleuchten: die Wände blieben sonst im Dunkeln hell.
      wallGlow: 0,
    );
  }

  /// Dunkel: Abend, wenig Umgebungslicht, die Lampen tragen das Bild.
  factory SceneStyle.dark() => const SceneStyle(
    // Linien hell: vor dunklen Böden und Wänden gut zu sehen.
    ink: Color(0xFFC2C7CF),
    // Helle Grundfarben, wenig Licht: Dunkel kommt vom Licht, nicht von
    // der Farbe. So hellen Lampen die Möbel sichtbar warm auf.
    surface: Color(0xFFB4B8BF),
    soft: Color(0xFFADB1B9),
    // Boden und Wände hell (fast weißes Grau), damit die Wohnung auch ohne
    // Licht klar vor dem dunklen Hintergrund steht.
    floor: Color(0xFFB3B6BD),
    wall: Color(0xFFE2E4E8),
    accent: Color(0xFF5B9BFF),
    dark: Color(0xFF6E727A),
    green: Color(0xFF6E9E70),
    // Etwas Grundlicht: unbeleuchtete Räume bleiben dunkel, aber lesbar.
    ambient: 0.27,
    sun: 0.1,
    roomEdgeOpacity: 0.85,
    // Abends streut das Lampenlicht stärker in die Schatten.
    shadowFill: 0.5,
    wallOpacity: 0.62,
    floorOpacity: 0.92,
    // Eigene Möbelfarben passend zu den gedämpften Grundfarben.
    paintScale: 0.84,
  );

  /// Kanten (nur echte Knicke und Ränder).
  final Color ink;

  /// Möbelflächen ([Mat.body]).
  final Color surface;

  /// Polster ([Mat.soft]). [dark] ist bewusst kein Schwarz, sondern ein
  /// mittleres Grau (Bildschirme, Kochfeld).
  final Color soft;
  final Color floor;
  final Color wall;

  /// Auswahl.
  final Color accent;
  final Color glass;
  final Color dark;
  final Color green;

  /// Mindestbreite der Kanten in logischen Pixeln: beim Herauszoomen werden
  /// sie nie schmaler.
  final double edgeWidth;

  /// Anteil des Lichts (Sonne, Lampen), der als Streulicht in die Schatten
  /// fällt, in der Farbe der Quelle: 0 harte, dunkle Schatten, 1 keine.
  final double shadowFill;

  /// Eigenes Leuchten der Wände in ihrer Farbe (0 … 1): hält sie auch bei
  /// trübem Himmelslicht hell.
  final double wallGlow;

  /// Mindestens so viel Grundlicht unter dem Himmel (nachts): hell lesbar,
  /// im dunklen Design niedriger, damit Räume ohne Licht nachts dunkel
  /// werden und beleuchtete (Raumlicht) hervortreten.
  final double skyMinAmbient;

  /// Deckkraft der Raumumrisse (Wandoberkanten) im Verhältnis zu den
  /// Möbelkanten.
  final double roomEdgeOpacity;

  /// Spalt zwischen Nachbarräumen in Metern (wie in der 2D-Karte).
  final double roomGap;

  /// Eckenradius der Räume in Metern.
  final double roomRadius;

  /// Breite der Kanten in Metern: beim Hineinzoomen werden sie mit den
  /// Möbeln kräftiger (aber nie schmaler als [edgeWidth] Pixel).
  final double edgeWorldWidth;

  /// Kantenbreite in Metern bei [pixelsPerMeter].
  double edgeWidthAt(double pixelsPerMeter) =>
      math.max(edgeWorldWidth, edgeWidth / pixelsPerMeter);

  /// Deckkraft der Wände (darunter scheinen Nachbarräume durch).
  final double wallOpacity;

  /// Deckkraft der Böden (darunter scheint der Hintergrund durch).
  final double floorOpacity;

  /// Wände, die zur Kamera zeigen, ausblenden.
  final bool cutaway;

  /// Umgebungslicht (0 = keins, 1 = hell).
  final double ambient;

  /// Stärke des Hauptlichts schräg von oben (wirft die Schatten).
  final double sun;

  /// Weiche Schatten des Hauptlichts.
  final bool shadows;

  /// Stärke der Lampen (Punktlichter an eingeschalteten Leuchten).
  final double lampGlow;

  /// Kanten und Linien nur in der Draufsicht; beim Kippen blenden sie weich
  /// aus und die Form kommt allein aus der Schattierung.
  final bool edgesOnlyFromAbove;

  /// Helligkeit eigener Farben ([paint]) im Verhältnis zur gewählten
  /// Farbe: 1 im hellen Stil, darunter im dunklen (dessen Grundfarben auch
  /// gedämpft sind).
  final double paintScale;

  Color base(Mat m) => switch (m) {
    Mat.body => surface,
    Mat.soft => soft,
    Mat.glass => glass,
    Mat.dark => dark,
    Mat.green => green,
    Mat.rug => Color.lerp(floor, soft, 0.6)!,
    Mat.wall => wall,
    Mat.screen => Color.lerp(dark, const Color(0xFF1E2126), 0.62)!,
    Mat.ceramic => Color.lerp(surface, const Color(0xFFFFFFFF), 0.5)!,
    Mat.metal => Color.lerp(dark, surface, 0.5)!,
  };

  /// Eigene Farbe [c] (Farbzone eines Möbelstücks) in diesem Stil.
  Color paint(Color c) {
    if (paintScale == 1) return c.withValues(alpha: 1);
    return Color.from(
      alpha: 1,
      red: c.r * paintScale,
      green: c.g * paintScale,
      blue: c.b * paintScale,
    );
  }

  /// Grundfarbe der Zone [mat] mit eigener Farbe [c] (oder ohne).
  Color colorOf(Mat mat, Color? c) => c == null ? base(mat) : paint(c);

  SceneStyle copyWith({
    Color? ink,
    Color? accent,
    double? wallOpacity,
    double? floorOpacity,
    bool? cutaway,
    double? ambient,
    double? sun,
    bool? shadows,
    double? lampGlow,
    bool? edgesOnlyFromAbove,
    double? edgeWidth,
    double? edgeWorldWidth,
    double? roomGap,
    double? roomRadius,
    double? roomEdgeOpacity,
    double? shadowFill,
    double? wallGlow,
    double? skyMinAmbient,
    double? paintScale,
  }) => SceneStyle(
    ink: ink ?? this.ink,
    surface: surface,
    soft: soft,
    floor: floor,
    wall: wall,
    accent: accent ?? this.accent,
    glass: glass,
    dark: dark,
    green: green,
    edgeWidth: edgeWidth ?? this.edgeWidth,
    edgeWorldWidth: edgeWorldWidth ?? this.edgeWorldWidth,
    roomGap: roomGap ?? this.roomGap,
    roomRadius: roomRadius ?? this.roomRadius,
    roomEdgeOpacity: roomEdgeOpacity ?? this.roomEdgeOpacity,
    shadowFill: shadowFill ?? this.shadowFill,
    wallGlow: wallGlow ?? this.wallGlow,
    skyMinAmbient: skyMinAmbient ?? this.skyMinAmbient,
    paintScale: paintScale ?? this.paintScale,
    wallOpacity: wallOpacity ?? this.wallOpacity,
    floorOpacity: floorOpacity ?? this.floorOpacity,
    cutaway: cutaway ?? this.cutaway,
    ambient: ambient ?? this.ambient,
    sun: sun ?? this.sun,
    shadows: shadows ?? this.shadows,
    lampGlow: lampGlow ?? this.lampGlow,
    edgesOnlyFromAbove: edgesOnlyFromAbove ?? this.edgesOnlyFromAbove,
  );

  @override
  bool operator ==(Object other) =>
      other is SceneStyle &&
      other.ink == ink &&
      other.surface == surface &&
      other.soft == soft &&
      other.floor == floor &&
      other.wall == wall &&
      other.accent == accent &&
      other.glass == glass &&
      other.dark == dark &&
      other.green == green &&
      other.edgeWidth == edgeWidth &&
      other.edgeWorldWidth == edgeWorldWidth &&
      other.roomGap == roomGap &&
      other.roomRadius == roomRadius &&
      other.roomEdgeOpacity == roomEdgeOpacity &&
      other.shadowFill == shadowFill &&
      other.wallGlow == wallGlow &&
      other.skyMinAmbient == skyMinAmbient &&
      other.paintScale == paintScale &&
      other.wallOpacity == wallOpacity &&
      other.floorOpacity == floorOpacity &&
      other.cutaway == cutaway &&
      other.ambient == ambient &&
      other.sun == sun &&
      other.shadows == shadows &&
      other.lampGlow == lampGlow &&
      other.edgesOnlyFromAbove == edgesOnlyFromAbove;

  @override
  int get hashCode => Object.hashAll([
    ink,
    surface,
    soft,
    floor,
    wall,
    accent,
    glass,
    dark,
    green,
    edgeWidth,
    edgeWorldWidth,
    roomGap,
    roomRadius,
    roomEdgeOpacity,
    shadowFill,
    wallGlow,
    skyMinAmbient,
    paintScale,
    wallOpacity,
    floorOpacity,
    cutaway,
    ambient,
    sun,
    shadows,
    lampGlow,
    edgesOnlyFromAbove,
  ]);
}
