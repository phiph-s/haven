import 'package:material_ui/material_ui.dart';

import '../../../core/widgets/haven_sheet.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/press_scale.dart';
import '../zigbee_model.dart';

// ---- Formatierung -------------------------------------------------------

/// Zahl mit Komma und höchstens [digits] Nachkommastellen, ohne Nullen am Ende.
String fmtNum(num v, {int digits = 1}) {
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return s.replaceAll('.', ',');
}

/// Einheiten aus Z2M in lesbarer Form.
String unitLabel(String? u) => switch (u) {
  null => '',
  'minutes' => 'min',
  'seconds' => 's',
  'lqi' => '',
  'mired' => 'mired',
  final x => x,
};

String durationLabel(num seconds) {
  if (seconds < 60) return '${fmtNum(seconds, digits: 0)} s';
  if (seconds < 3600) return '${fmtNum(seconds / 60)} min';
  return '${fmtNum(seconds / 3600)} h';
}

/// „vor 3 Min“, „vor 2 Std“, „vor 4 Tagen“.
String agoLabel(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} Min';
  if (d.inHours < 24) return 'vor ${d.inHours} Std';
  final days = d.inDays;
  return days == 1 ? 'vor 1 Tag' : 'vor $days Tagen';
}

String powerSourceLabel(String? s) {
  final l = (s ?? '').toLowerCase();
  if (l.contains('battery')) return 'Batterie';
  if (l.contains('mains')) return 'Netzstrom';
  if (l.contains('usb')) return 'USB';
  if (l.contains('dc')) return 'Gleichstrom';
  return s == null || s.isEmpty ? 'unbekannt' : s;
}

String nodeTypeLabel(String type) => switch (type) {
  'Router' => 'Router (leitet Funk weiter)',
  'Coordinator' => 'Koordinator',
  _ => 'Endgerät',
};

String deviceTypeLabel(String t) => switch (t) {
  'light' => 'Lampe',
  'plug_meter' => 'Steckdose mit Messung',
  'switch' => 'Schalter',
  'relay' => 'Unterputz-Relais',
  'climate_sensor' => 'Klimasensor',
  'motion' => 'Bewegungsmelder',
  'presence' => 'Anwesenheitssensor',
  'contact' => 'Tür- und Fensterkontakt',
  'remote' => 'Taster',
  'knob' => 'Drehregler',
  'thermostat' => 'Thermostat',
  _ => 'Gerät',
};

/// Letzte Aktion eines Tasters oder Drehreglers auf Deutsch.
String actionLabel(String? a) {
  if (a == null || a.isEmpty) return 'Noch nichts empfangen';
  const m = {
    'single': 'Einmal gedrückt',
    'double': 'Doppelt gedrückt',
    'hold': 'Gehalten',
    'long': 'Lang gedrückt',
    'rotate_right': 'Nach rechts gedreht',
    'rotate_left': 'Nach links gedreht',
    'press': 'Gedrückt',
    'release': 'Losgelassen',
    'toggle': 'Umgeschaltet',
    'on': 'Eingeschaltet',
    'off': 'Ausgeschaltet',
  };
  return m[a] ?? a.replaceAll('_', ' ');
}

Color lqiColor(BuildContext context, int lqi) {
  final hv = context.hv;
  return switch (LqiLevel.of(lqi)) {
    LqiLevel.good => hv.ok,
    LqiLevel.medium => hv.warn,
    LqiLevel.weak => hv.bad,
  };
}

Color batteryColor(BuildContext context, int pct) {
  final hv = context.hv;
  return pct < kLowBattery ? hv.bad : (pct < 50 ? hv.warn : hv.ok);
}

// ---- Toast ----------------------------------------------------------------

/// Kurze Rückmeldung von oben. Läuft über einen Controller, damit keine Timer
/// offen bleiben.
void zbToast(BuildContext context, String message, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      error: error,
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.error,
    required this.onDone,
  });
  final String message;
  final bool error;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final top = MediaQuery.of(context).padding.top + 12;
    return Positioned(
      top: top,
      left: 20,
      right: 20,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = _c.value;
            final inT = (t / 0.12).clamp(0.0, 1.0);
            final outT = ((1 - t) / 0.1).clamp(0.0, 1.0);
            final p = context.reduceMotion
                ? 1.0
                : HavenMotion.spring.transform(inT);
            return Opacity(
              opacity: (inT * outT).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, -28 * (1 - p)),
                child: child,
              ),
            );
          },
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: hv.s1,
                borderRadius: BorderRadius.circular(HavenRadii.m),
                border: Border.all(color: widget.error ? hv.bad : hv.ln2),
                boxShadow: hv.shadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.error
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 20,
                    color: widget.error ? hv.bad : hv.ok,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.message,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Sheet ----------------------------------------------------------------

/// Bottom-Sheet im Stil der App (s1, 34 dp Radius, Griff).
Future<T?> showZbSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scroll = true,
}) {
  return showHavenModalSheet<T>(
    context,
    builder: (ctx) {
      final hv = ctx.hv;
      final media = MediaQuery.of(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: hv.s1,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(HavenRadii.xl),
              ),
              border: Border.all(color: hv.ln),
            ),
            child: SingleChildScrollView(
              // Am oberen Ende übernimmt das Sheet das Ziehen.
              controller: HavenSheetScope.maybeOf(ctx)?.scrollController,
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                20 + media.padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: hv.s3,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  builder(ctx),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Zeile mit Auswahlmarke für Sheets.
class ZbChoiceRow extends StatelessWidget {
  const ZbChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return PressScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: HavenSpace.touch),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: selected ? hv.acc.withValues(alpha: 0.14) : hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(color: selected ? hv.acc : hv.ln),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_rounded, color: hv.acc, size: 22),
          ],
        ),
      ),
    );
  }
}

/// Kleine Pille (Batterie, Signal, Offline).
class ZbPill extends StatelessWidget {
  const ZbPill({super.key, required this.text, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(HavenRadii.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
        ],
        Text(
          text,
          style: HavenText.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 11.5,
          ),
        ),
      ],
    ),
  );
}
