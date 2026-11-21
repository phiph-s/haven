import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/router/router.dart' show Routes;
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/haven_repository.dart';
import '../../data/models/lamp.dart';
import '../../data/models/lamp_calibration.dart';
import '../room/widgets/color_controls.dart' show KelvinSlider;
import '../zigbee/widgets/zb_common.dart' show zbToast;
import 'lamp_types.dart';
import 'settings_widgets.dart';

/// Untertitel der Zeile in den Einstellungen.
String lampCalibrationSubtitle(List<LampType> types, LampCalibrations cal) {
  if (types.isEmpty) return 'Keine Lampenmodelle bekannt';
  final n = types.length;
  final adjusted = types.where((t) => !cal.of(t.model).isIdentity).length;
  final base = '$n ${n == 1 ? 'Lampentyp' : 'Lampentypen'}';
  return adjusted == 0 ? base : '$base, $adjusted angepasst';
}

/// Zeile in den Einstellungen (Zuhause).
class LampCalibrationSettingsRow extends ConsumerWidget {
  const LampCalibrationSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(snapshotProvider);
    return SettingsRow(
      icon: Icons.tune_rounded,
      title: 'Lampen kalibrieren',
      subtitle: lampCalibrationSubtitle(
        lampTypesOf(snap),
        snap.lampCalibration,
      ),
      onTap: () => context.push(Routes.lampCalibration),
    );
  }
}

Widget _header(BuildContext context, String title) {
  final hv = context.hv;
  return Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
    child: Row(
      children: [
        RoundIconButton(
          icon: Icons.arrow_back_rounded,
          label: 'Zurück',
          onTap: () => context.pop(),
        ),
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HavenText.headline.copyWith(color: hv.tx, fontSize: 22),
          ),
        ),
        const SizedBox(width: HavenSpace.touch),
      ],
    ),
  );
}

Widget _caption(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
  child: Text(text, style: HavenText.caption.copyWith(color: context.hv.tx2)),
);

Widget _section(BuildContext context, String t) => Padding(
  padding: const EdgeInsets.fromLTRB(24, 24, 20, 10),
  child: Text(t, style: HavenText.section.copyWith(color: context.hv.tx)),
);

Widget _pad(Widget w) =>
    Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: w);

/// Einstellungen › Lampen kalibrieren: die Lampentypen der Installation.
class LampCalibrationScreen extends ConsumerWidget {
  const LampCalibrationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    final types = lampTypesOf(snap);
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            _header(context, 'Lampen kalibrieren'),
            _caption(
              context,
              'Wirkt eine Lampe in echt wärmer, kälter, heller oder dunkler '
              'als in Haven, stellst du das hier je Lampentyp ein. Die '
              'Korrektur gilt für Karte, Raumbilder und Lichtfarben, auf '
              'allen Geräten. Die Lampen selbst schaltet sie nicht anders.',
            ),
            const SizedBox(height: 18),
            if (types.isEmpty)
              _caption(
                context,
                'Haven kennt die Modelle deiner Lampen noch nicht. Sie kommen '
                'aus Zigbee2MQTT bzw. dem Geräteregister von Home Assistant.',
              )
            else
              _pad(
                SettingsGroup(
                  children: [
                    for (final t in types)
                      _TypeRow(
                        type: t,
                        calibration: snap.lampCalibration.of(t.model),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({required this.type, required this.calibration});

  final LampType type;
  final LampCalibration calibration;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final n = type.lamps.length;
    final count = '$n ${n == 1 ? 'Lampe' : 'Lampen'}';
    final sample = type.lamps.first.name;
    final adjusted = !calibration.isIdentity;
    final shown = [
      for (final k in type.anchors)
        colorOf(kelvinToRgb(calibration.mapKelvin(k))),
    ];
    return SettingsRow(
      icon: Icons.lightbulb_outline_rounded,
      iconColor: adjusted ? hv.acc : null,
      title: type.model.label,
      subtitle: [
        count,
        n == 1 ? sample : 'z. B. $sample',
        if (adjusted) 'angepasst',
      ].join(' · '),
      onTap: () => context.push(Routes.lampType(type.key)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in shown)
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(left: 3),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: hv.ln2),
              ),
            ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, color: hv.tx3),
        ],
      ),
    );
  }
}

/// Kalibrierung eines Lampentyps: Vorschau, Weißtöne, Helligkeit und ein
/// Testwert für eine echte Lampe.
class LampTypeCalibrationScreen extends ConsumerStatefulWidget {
  const LampTypeCalibrationScreen({super.key, required this.modelKey});

  final String modelKey;

  @override
  ConsumerState<LampTypeCalibrationScreen> createState() =>
      _LampTypeCalibrationScreenState();
}

/// Helligkeiten der Vorschau in Prozent.
const List<int> _previewLevels = [10, 25, 50, 75, 100];

class _LampTypeCalibrationScreenState
    extends ConsumerState<LampTypeCalibrationScreen> {
  late final HavenRepository _repo = ref.read(repositoryProvider);
  late LampCalibration _draft =
      _repo.snapshot.lampCalibration.byModel[widget.modelKey] ??
      LampCalibration.none;
  Timer? _saveTimer;
  int? _testKelvin;
  int _testLevel = 50;
  String? _target;
  bool _testing = false;

  /// Lichtzustand vor dem Test, je Lampe (wird beim Verlassen
  /// wiederhergestellt).
  final Map<String, Lamp> _before = {};

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      unawaited(_save(quiet: true));
    }
    if (_before.isNotEmpty) unawaited(_restore(quiet: true));
    super.dispose();
  }

  void _change(LampCalibration next) {
    setState(() => _draft = next);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save({bool quiet = false}) async {
    final all = _repo.snapshot.lampCalibration.withModel(
      widget.modelKey,
      _draft,
    );
    try {
      await _repo.setLampCalibration(all);
    } catch (e) {
      if (!quiet && mounted) {
        zbToast(context, 'Nicht gespeichert. $e', error: true);
      }
    }
  }

  Future<void> _test(LampType type, int kelvin) async {
    final id = _target ?? _defaultTarget(type);
    if (id == null) return;
    final now = _repo.snapshot.lamp(id);
    if (now == null) return;
    _before.putIfAbsent(id, () => now);
    setState(() => _testing = true);
    try {
      await _repo.setLights(
        [id],
        on: true,
        brightness: _testLevel,
        kelvin: now.supportsKelvin ? kelvin : null,
      );
    } catch (e) {
      if (mounted) zbToast(context, 'Lampe nicht erreicht. $e', error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _restore({bool quiet = false}) async {
    final before = Map.of(_before);
    _before.clear();
    if (!quiet && mounted) setState(() {});
    for (final e in before.entries) {
      final l = e.value;
      try {
        if (!l.on) {
          await _repo.setLights([e.key], on: false);
        } else if (l.kelvin != null && l.isWhite) {
          await _repo.setLights(
            [e.key],
            on: true,
            brightness: l.brightness,
            kelvin: l.kelvin,
          );
        } else if (l.supportsColor) {
          await _repo.setLights(
            [e.key],
            on: true,
            brightness: l.brightness,
            rgb: l.color,
          );
        } else {
          await _repo.setLights([e.key], on: true, brightness: l.brightness);
        }
      } catch (err) {
        if (!quiet && mounted) {
          zbToast(context, 'Nicht wiederhergestellt. $err', error: true);
        }
      }
    }
  }

  String? _defaultTarget(LampType type) {
    for (final l in type.lamps) {
      if (l.available) return l.entityId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    LampType? type;
    for (final t in lampTypesOf(snap)) {
      if (t.key == widget.modelKey) type = t;
    }
    if (type == null) {
      return Scaffold(
        backgroundColor: hv.bg,
        body: SafeArea(
          child: ListView(
            children: [
              _header(context, 'Lampen kalibrieren'),
              _caption(context, 'Dieser Lampentyp ist nicht mehr da.'),
            ],
          ),
        ),
      );
    }
    final t = type;
    final testKelvin = _testKelvin ?? t.anchors.first;
    final names = t.lamps.map((l) => l.name).join(', ');
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            _header(context, t.model.label),
            _caption(
              context,
              [
                if (t.model.description?.isNotEmpty ?? false)
                  t.model.description!,
                '${t.lamps.length == 1 ? 'Lampe' : '${t.lamps.length} Lampen'}: $names',
              ].join('\n'),
            ),
            _section(context, 'Vorschau'),
            _pad(
              HavenCard(
                child: _Preview(
                  type: t,
                  calibration: _draft,
                  kelvin: testKelvin,
                  level: _testLevel,
                  onKelvin: (k) => setState(() => _testKelvin = k),
                  onLevel: (b) => setState(() => _testLevel = b),
                ),
              ),
            ),
            _section(context, 'Mit echter Lampe vergleichen'),
            _pad(
              HavenCard(
                child: _TestPanel(
                  type: t,
                  target: _target ?? _defaultTarget(t),
                  kelvin: testKelvin,
                  level: _testLevel,
                  busy: _testing,
                  canRestore: _before.isNotEmpty,
                  onTarget: (id) => setState(() => _target = id),
                  onTest: () => _test(t, testKelvin),
                  onRestore: _restore,
                ),
              ),
            ),
            _section(context, t.hasKelvin ? 'Weißtöne' : 'Lichtfarbe'),
            _pad(
              HavenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final a in t.anchors)
                      _AnchorSlider(
                        anchor: a,
                        fixed: !t.hasKelvin,
                        shown: _draft.shownAt(a),
                        onChanged: (k) =>
                            _change(_draft.withWhite(a, k, anchors: t.anchors)),
                      ),
                    Text(
                      'Wirkt die Lampe in echt kälter als in Haven, schiebe '
                      'nach rechts, wirkt sie wärmer, nach links. Dazwischen '
                      'rechnet Haven gleichmäßig weiter.',
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
            ),
            _section(context, 'Helligkeit'),
            _pad(
              HavenCard(
                child: _BrightnessControls(
                  calibration: _draft,
                  onChanged: _change,
                ),
              ),
            ),
            if (!_draft.isIdentity) ...[
              const SizedBox(height: 20),
              _pad(
                HavenButton(
                  label: 'Korrektur zurücksetzen',
                  icon: Icons.restart_alt_rounded,
                  destructive: true,
                  onTap: () => _change(LampCalibration.none),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Vorschaufeld: oben wie gemeldet, unten wie angezeigt.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.reported,
    required this.shown,
    required this.selected,
    required this.onTap,
    required this.semantics,
  });

  final String label;
  final Rgb reported;
  final Rgb shown;
  final bool selected;
  final VoidCallback onTap;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: semantics,
        excludeSemantics: true,
        child: PressScale(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Column(
              children: [
                Container(
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HavenRadii.s),
                    border: Border.all(
                      color: selected ? hv.acc : hv.ln2,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: colorOf(reported),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: colorOf(shown),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  style: HavenText.caption.copyWith(
                    color: selected ? hv.tx : hv.tx2,
                    fontWeight: selected ? FontWeight.w700 : null,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.type,
    required this.calibration,
    required this.kelvin,
    required this.level,
    required this.onKelvin,
    required this.onLevel,
  });

  final LampType type;
  final LampCalibration calibration;
  final int kelvin;
  final int level;
  final ValueChanged<int> onKelvin;
  final ValueChanged<int> onLevel;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final kelvins = {...type.previewKelvins, kelvin}.toList()..sort();
    final shownWhite = kelvinToRgb(calibration.mapKelvin(kelvin));
    final reportedWhite = kelvinToRgb(kelvin);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Oben wie bisher, unten mit Korrektur. Tippe einen Wert an, um ihn '
          'mit der echten Lampe zu vergleichen.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        if (type.hasKelvin) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              for (final k in kelvins)
                _Swatch(
                  label: '$k K',
                  reported: kelvinToRgb(k),
                  shown: kelvinToRgb(calibration.mapKelvin(k)),
                  selected: k == kelvin,
                  onTap: () => onKelvin(k),
                  semantics:
                      '$k Kelvin, angezeigt wie ${calibration.mapKelvin(k)} Kelvin',
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            for (final b in _previewLevels)
              _Swatch(
                label: '$b %',
                reported: swatchAt(reportedWhite, b / 100),
                shown: swatchAt(shownWhite, calibration.mapLevel(b / 100)),
                selected: b == level,
                onTap: () => onLevel(b),
                semantics:
                    '$b Prozent, angezeigt wie ${shownPercent(calibration, b)} Prozent',
              ),
          ],
        ),
      ],
    );
  }
}

class _TestPanel extends StatelessWidget {
  const _TestPanel({
    required this.type,
    required this.target,
    required this.kelvin,
    required this.level,
    required this.busy,
    required this.canRestore,
    required this.onTarget,
    required this.onTest,
    required this.onRestore,
  });

  final LampType type;
  final String? target;
  final int kelvin;
  final int level;
  final bool busy;
  final bool canRestore;
  final ValueChanged<String> onTarget;
  final VoidCallback onTest;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Lamp? lamp;
    for (final l in type.lamps) {
      if (l.entityId == target) lamp = l;
    }
    final what = type.hasKelvin ? '$kelvin K und $level %' : '$level %';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (type.lamps.length > 1) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final l in type.lamps)
                ChoiceChip(
                  label: Text(l.name),
                  selected: l.entityId == target,
                  onSelected: l.available ? (_) => onTarget(l.entityId) : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Text(
          lamp == null
              ? 'Keine Lampe dieses Typs ist erreichbar.'
              : 'Setzt ${lamp.name} auf $what. Vergleiche sie mit dem unteren '
                    'Feld der Vorschau. Beim Verlassen der Seite bekommt die '
                    'Lampe ihr voriges Licht zurück.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: HavenButton(
                label: 'An Lampe zeigen',
                icon: Icons.lightbulb_rounded,
                primary: true,
                busy: busy,
                onTap: lamp == null ? null : onTest,
              ),
            ),
            if (canRestore) ...[
              const SizedBox(width: 10),
              Expanded(
                child: HavenButton(
                  label: 'Zurückstellen',
                  icon: Icons.undo_rounded,
                  onTap: onRestore,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// „2700 K wirkt wie …“ mit Weißton-Regler.
class _AnchorSlider extends StatelessWidget {
  const _AnchorSlider({
    required this.anchor,
    required this.fixed,
    required this.shown,
    required this.onChanged,
  });

  final int anchor;

  /// Lampe ohne Farbtemperatur: Es gibt nur ihre eine Lichtfarbe.
  final bool fixed;
  final int shown;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final lo = math.max(1500, (anchor * 0.6).round());
    final hi = math.min(10000, (anchor * 1.6).round());
    final changed = shown != anchor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  fixed ? 'Die Lampe leuchtet wie' : '$anchor K wirkt wie',
                  style: HavenText.label.copyWith(color: hv.tx),
                ),
              ),
              Text(
                '$shown K',
                style: HavenText.label.copyWith(
                  color: changed ? hv.acc : hv.tx2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          KelvinSlider(
            key: ValueKey('anchor-$anchor'),
            kelvin: shown,
            min: lo,
            max: hi,
            onChanged: (k) => onChanged((k / 50).round() * 50),
          ),
        ],
      ),
    );
  }
}

class _BrightnessControls extends StatelessWidget {
  const _BrightnessControls({
    required this.calibration,
    required this.onChanged,
  });

  final LampCalibration calibration;
  final ValueChanged<LampCalibration> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final c = calibration;
    // Regler „Untere Stufen“: rechts heller (Gamma < 1), links dunkler.
    final lowV = -math.log(c.gamma) / math.ln2;
    Widget row(String label, String value, Widget slider) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: HavenText.label.copyWith(color: hv.tx)),
            ),
            Text(value, style: HavenText.label.copyWith(color: hv.tx2)),
          ],
        ),
        slider,
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
          'Insgesamt',
          '${(c.gain * 100).round()} %',
          Slider(
            value: c.gain.clamp(
              LampCalibration.minGain,
              LampCalibration.maxGain,
            ),
            min: LampCalibration.minGain,
            max: LampCalibration.maxGain,
            divisions: 24,
            semanticFormatterCallback: (v) => '${(v * 100).round()} Prozent',
            onChanged: (v) => onChanged(c.copyWith(gain: _snap(v, 0.05))),
          ),
        ),
        row(
          'Untere Stufen',
          lowV.abs() < 0.01 ? 'unverändert' : (lowV > 0 ? 'heller' : 'dunkler'),
          Slider(
            value: lowV.clamp(-1.0, 1.0),
            min: -1,
            max: 1,
            divisions: 20,
            semanticFormatterCallback: (v) =>
                v.abs() < 0.01 ? 'unverändert' : (v > 0 ? 'heller' : 'dunkler'),
            onChanged: (v) => onChanged(
              c.copyWith(
                gamma: _snap(
                  math.pow(2, -v).toDouble(),
                  0.01,
                ).clamp(LampCalibration.minGamma, LampCalibration.maxGamma),
              ),
            ),
          ),
        ),
        Text(
          'Bei 10 % wirkt sie wie ${shownPercent(c, 10)} %, bei 50 % wie '
          '${shownPercent(c, 50)} %, bei 100 % wie ${shownPercent(c, 100)} %.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
      ],
    );
  }
}

/// Auf Schritte runden, ohne Gleitkomma-Reste (1,0 soll genau 1 sein).
double _snap(double v, double step) =>
    ((v / step).round() * step * 1000).round() / 1000;
