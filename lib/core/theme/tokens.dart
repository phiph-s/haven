import 'package:material_ui/material_ui.dart';

/// Farb-Tokens nach design/spec.md, Abschnitt 1. Hell und Dunkel sind zwei
/// getrennte Paletten, Hell ist nicht invertiert.
@immutable
class HavenColors extends ThemeExtension<HavenColors> {
  const HavenColors({
    required this.brightness,
    required this.bg,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.tx,
    required this.tx2,
    required this.tx3,
    required this.ln,
    required this.ln2,
    required this.acc,
    required this.acc2,
    required this.ai,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.shadow,
    required this.shadowSmall,
    required this.tileGlow,
    required this.ambientGlow,
  });

  final Brightness brightness;
  final Color bg;
  final Color s1;
  final Color s2;
  final Color s3;
  final Color tx;
  final Color tx2;
  final Color tx3;
  final Color ln;
  final Color ln2;

  /// Akzent und Zweitakzent. Ohne Licht ein zurückhaltendes Violett, sonst
  /// von der Lichtfarbe des Bildschirms überschrieben.
  final Color acc;
  final Color acc2;

  /// Schrift auf Akzentflächen.
  final Color ai;
  final Color ok;
  final Color warn;
  final Color bad;
  final List<BoxShadow> shadow;
  final List<BoxShadow> shadowSmall;

  /// Modusfaktoren der Glow-Deckkraft (Spec 2.4).
  final double tileGlow;
  final double ambientGlow;

  bool get isDark => brightness == Brightness.dark;

  static const HavenColors dark = HavenColors(
    brightness: Brightness.dark,
    bg: Color(0xFF0D0C12),
    s1: Color(0xFF17151F),
    s2: Color(0xFF211E2B),
    s3: Color(0xFF2D2939),
    tx: Color(0xFFF5F1FB),
    tx2: Color(0xFFBDB6CB),
    tx3: Color(0xFF968FA5),
    ln: Color(0x14FFFFFF),
    ln2: Color(0x24FFFFFF),
    acc: Color(0xFFB9AAFF),
    acc2: Color(0xFF8F7BFF),
    ai: Color(0xFF17121F),
    ok: Color(0xFF3EE0A6),
    warn: Color(0xFFFFC14D),
    bad: Color(0xFFFF7078),
    shadow: [
      BoxShadow(
        color: Color(0x59000000),
        blurRadius: 30,
        offset: Offset(0, 12),
      ),
    ],
    shadowSmall: [
      BoxShadow(color: Color(0x40000000), blurRadius: 10, offset: Offset(0, 3)),
    ],
    tileGlow: 0.95,
    ambientGlow: 0.75,
  );

  static const HavenColors light = HavenColors(
    brightness: Brightness.light,
    bg: Color(0xFFF6F1EA),
    s1: Color(0xFFFFFFFF),
    s2: Color(0xFFEFE8DE),
    s3: Color(0xFFE2D9CB),
    tx: Color(0xFF1D1923),
    tx2: Color(0xFF575063),
    tx3: Color(0xFF6C6477),
    ln: Color(0x17281932),
    ln2: Color(0x29281932),
    acc: Color(0xFF6A50E8),
    acc2: Color(0xFF8D77FF),
    ai: Color(0xFFFFFFFF),
    ok: Color(0xFF12906A),
    warn: Color(0xFFA96A00),
    bad: Color(0xFFD1343F),
    shadow: [
      BoxShadow(
        color: Color(0x1F503720),
        blurRadius: 34,
        offset: Offset(0, 14),
      ),
    ],
    shadowSmall: [
      BoxShadow(color: Color(0x1A503720), blurRadius: 10, offset: Offset(0, 3)),
    ],
    tileGlow: 0.7,
    ambientGlow: 0.6,
  );

  /// Übernimmt Akzent aus einer Raumpalette. Rest bleibt.
  HavenColors withAccent(Color a, Color a2, Color onA) =>
      copyWith(acc: a, acc2: a2, ai: onA);

  @override
  HavenColors copyWith({Color? acc, Color? acc2, Color? ai}) => HavenColors(
    brightness: brightness,
    bg: bg,
    s1: s1,
    s2: s2,
    s3: s3,
    tx: tx,
    tx2: tx2,
    tx3: tx3,
    ln: ln,
    ln2: ln2,
    acc: acc ?? this.acc,
    acc2: acc2 ?? this.acc2,
    ai: ai ?? this.ai,
    ok: ok,
    warn: warn,
    bad: bad,
    shadow: shadow,
    shadowSmall: shadowSmall,
    tileGlow: tileGlow,
    ambientGlow: ambientGlow,
  );

  @override
  HavenColors lerp(ThemeExtension<HavenColors>? other, double t) {
    if (other is! HavenColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return HavenColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: l(bg, other.bg),
      s1: l(s1, other.s1),
      s2: l(s2, other.s2),
      s3: l(s3, other.s3),
      tx: l(tx, other.tx),
      tx2: l(tx2, other.tx2),
      tx3: l(tx3, other.tx3),
      ln: l(ln, other.ln),
      ln2: l(ln2, other.ln2),
      acc: l(acc, other.acc),
      acc2: l(acc2, other.acc2),
      ai: l(ai, other.ai),
      ok: l(ok, other.ok),
      warn: l(warn, other.warn),
      bad: l(bad, other.bad),
      shadow: BoxShadow.lerpList(shadow, other.shadow, t)!,
      shadowSmall: BoxShadow.lerpList(shadowSmall, other.shadowSmall, t)!,
      tileGlow: tileGlow + (other.tileGlow - tileGlow) * t,
      ambientGlow: ambientGlow + (other.ambientGlow - ambientGlow) * t,
    );
  }
}

/// Radien nach Spec: s 12, m 18, l 26 (Kacheln, Karten), xl 34 (Sheets, Regler).
abstract final class HavenRadii {
  static const double s = 12;
  static const double m = 18;
  static const double l = 26;
  static const double xl = 34;
  static const double pill = 999;
}

/// Abstände: 4, 8, 12, 16, 24. Seitenrand 20.
abstract final class HavenSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 24;
  static const double page = 20;

  /// Mindest-Zielgröße für Bedienelemente.
  static const double touch = 48;

  /// Platz unter Listen für die schwebende Navigation.
  static const double navClearance = 120;
}

/// Typo-Skala. Systemschrift, Farbe kommt aus dem Kontext.
abstract final class HavenText {
  static const TextStyle display = TextStyle(
    fontSize: 38,
    fontWeight: FontWeight.w800,
    height: 1.05,
    letterSpacing: -0.76,
  );
  static const TextStyle title = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w800,
    height: 1.08,
    letterSpacing: -0.68,
  );
  static const TextStyle section = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w800,
    height: 1.2,
    letterSpacing: -0.2,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w800,
    height: 1.25,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const TextStyle label = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// Große Zahlen: Prozent im Raum und Leistung.
  static const TextStyle percent = TextStyle(
    fontSize: 64,
    fontWeight: FontWeight.w800,
    height: 1,
    letterSpacing: -2.56,
  );
  static const TextStyle power = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w800,
    height: 1.05,
    letterSpacing: -0.68,
  );
}

/// Motion-Konstanten. Gestrafft nach dem ersten Test auf dem Handy:
/// Übergänge 250 bis 350 ms, Mikro-Feedback 100 bis 150 ms, Federn mit wenig
/// Überschwingen (vorher 520 bis 800 ms und deutliches Nachfedern).
abstract final class HavenMotion {
  /// Leichtes Überschwingen (etwa 3 %), für Daumen, Blasen, Karten.
  static const Curve spring = Cubic(0.25, 1.12, 0.4, 1);

  /// Schnell raus, weich rein: Standard für Übergänge.
  static const Curve out = Cubic(0.2, 0.8, 0.2, 1);

  /// Mikro-Feedback: Drücken, Haken, kleine Zustandswechsel.
  static const Duration d1 = Duration(milliseconds: 120);

  /// Kleine Wechsel: Schalter, Segmente, Auf- und Zuklappen.
  static const Duration d2 = Duration(milliseconds: 200);

  /// Übergänge in einem Bildschirm.
  static const Duration d3 = Duration(milliseconds: 300);

  /// Farbe und Licht (Paletten, Glow). Darf etwas länger sein, weil es nur
  /// gezeichnet und nicht gelayoutet wird.
  static const Duration d4 = Duration(milliseconds: 450);

  /// Kachel zu Raum: öffnen und schließen.
  static const Duration roomOpen = Duration(milliseconds: 340);
  static const Duration roomClose = Duration(milliseconds: 280);

  /// Unterseiten (von rechts).
  static const Duration pageIn = Duration(milliseconds: 300);
  static const Duration pageOut = Duration(milliseconds: 250);

  /// Tabwechsel: Überblenden mit 10 px Versatz.
  static const Duration tabSwitch = Duration(milliseconds: 240);
  static const double tabOffset = 10;

  /// Feder für alles, was eine Hand bewegt (Regler, Schalter, Ziehen).
  /// Dämpfungsgrad etwa 0,85: kaum Überschwingen, setzt in etwa 250 ms.
  static const SpringDescription springDesc = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 35,
  );

  /// Skalierung beim Drücken (Spec: .95 bis .88).
  static const double pressScale = 0.95;
}

extension HavenThemeContext on BuildContext {
  HavenColors get hv => Theme.of(this).extension<HavenColors>()!;

  /// `MediaQuery.disableAnimations`: Dauer 0, keine Endlosanimationen.
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// Dauer, die Bewegungsreduzierung respektiert.
  Duration motion(Duration d) => reduceMotion ? Duration.zero : d;
}
