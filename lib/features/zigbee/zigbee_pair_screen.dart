import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/segmented.dart';
import '../../data/haven_repository.dart';
import '../../data/models/zigbee.dart';
import 'widgets/device_icon.dart';
import 'widgets/device_main.dart';
import 'widgets/zb_common.dart';
import 'zigbee_actions.dart';
import 'zigbee_providers.dart';

enum _Phase { explain, searching, timeout, interview, failed, naming, done }

const _kSearchSeconds = 240;

/// Assistent „Gerät hinzufügen“ im Vollbild:
/// Erklärung, Suche (4 Minuten), Interview, Name und Raum, Fertig.
class ZigbeePairScreen extends ConsumerStatefulWidget {
  const ZigbeePairScreen({super.key});

  @override
  ConsumerState<ZigbeePairScreen> createState() => _ZigbeePairScreenState();
}

class _ZigbeePairScreenState extends ConsumerState<ZigbeePairScreen>
    with SingleTickerProviderStateMixin {
  late final HavenRepository _repo = ref.read(repositoryProvider);
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );

  _Phase _phase = _Phase.explain;
  String _kind = 'lamp';
  int _remaining = _kSearchSeconds;
  String? _via; // IEEE des Routers, `null` = alle
  Timer? _tick;
  Timer? _next;
  StreamSubscription<ZbEvent>? _sub;
  bool _joined = false;
  bool _started = false;
  bool _recognized = false;
  String? _ieee;
  String? _model;
  String? _error;
  bool _searching = false;
  bool _saving = false;

  final TextEditingController _name = TextEditingController();
  String? _room;
  bool _roomTouched = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _anim.stop();
    } else if (!_anim.isAnimating) {
      _anim.repeat();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _next?.cancel();
    _sub?.cancel();
    if (_searching) _repo.zigbeeStopJoin().catchError((_) {});
    _anim.dispose();
    _name.dispose();
    super.dispose();
  }

  // ---- Ablauf ----

  Future<void> _startSearch() async {
    setState(() {
      _phase = _Phase.searching;
      _remaining = _kSearchSeconds;
      _joined = _started = _recognized = false;
      _ieee = _model = _error = null;
    });
    _sub?.cancel();
    _sub = _repo.zigbeeEvents.listen(_onEvent);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_phase != _Phase.searching) return;
      if (_remaining <= 1) {
        _tick?.cancel();
        _stopSearch();
        setState(() {
          _remaining = 0;
          _phase = _Phase.timeout;
        });
      } else {
        setState(() => _remaining--);
      }
    });
    await _openNetwork();
  }

  Future<void> _openNetwork() async {
    try {
      _searching = true;
      await _repo.zigbeePermitJoin(seconds: _remaining, viaIeee: _via);
    } catch (e) {
      _searching = false;
      _tick?.cancel();
      if (mounted) {
        setState(() {
          _error = '$e';
          _phase = _Phase.failed;
        });
      }
    }
  }

  void _stopSearch() {
    if (!_searching) return;
    _searching = false;
    _repo.zigbeeStopJoin().catchError((_) {});
  }

  void _onEvent(ZbEvent e) {
    if (e.kind != 'event' || !mounted) return;
    final d = e.bridgeData;
    final ieee = (d['ieee_address'] ?? d['ieee'])?.toString();
    switch (e.bridgeType) {
      case 'device_joined':
        _ieee ??= ieee;
        _tick?.cancel();
        setState(() {
          _joined = true;
          if (_phase == _Phase.searching) _phase = _Phase.interview;
        });
      case 'interview_started':
        _interviewStarted(ieee);
      case 'interview_successful':
        _interviewDone(ieee, d);
      case 'device_interview':
        final status = d['status'];
        if (status == 'started') _interviewStarted(ieee);
        if (status == 'successful') _interviewDone(ieee, d);
        if (status == 'failed') {
          _tick?.cancel();
          _stopSearch();
          setState(() {
            _error = 'Das Gerät hat sich gemeldet, aber die Einrichtung ist fehlgeschlagen. Setze es zurück und versuche es noch einmal.';
            _phase = _Phase.failed;
          });
        }
    }
  }

  void _interviewStarted(String? ieee) {
    _ieee ??= ieee;
    _tick?.cancel();
    setState(() {
      _joined = true;
      _started = true;
      if (_phase == _Phase.searching) _phase = _Phase.interview;
    });
  }

  void _interviewDone(String? ieee, Map<String, dynamic> d) {
    _ieee ??= ieee;
    _tick?.cancel();
    final def = d['definition'];
    setState(() {
      _joined = _started = _recognized = true;
      if (_phase == _Phase.searching) _phase = _Phase.interview;
      if (def is Map) {
        _model = [
          def['vendor'],
          def['model'],
        ].whereType<Object>().map((x) => '$x').join(' ');
      }
    });
    _stopSearch();
    _next?.cancel();
    // Kurz die Haken zeigen, dann zu Name und Raum.
    _next = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      _next = Timer(const Duration(milliseconds: 900), _toNaming);
    });
  }

  Future<void> _toNaming() async {
    if (!mounted) return;
    await ref.read(zigbeeProvider.notifier).reload();
    if (!mounted) return;
    final v = _ieee == null ? null : ref.read(zigbeeViewProvider(_ieee!));
    setState(() {
      _phase = _Phase.naming;
      _name.text = v == null ? 'Neues Gerät' : deviceTypeLabel(v.type);
      _name.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _name.text.length,
      );
    });
  }

  Future<void> _save() async {
    final ieee = _ieee;
    final name = _name.text.trim();
    if (ieee == null || name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final n = ref.read(zigbeeProvider.notifier);
    var err = await n.rename(ieee, name);
    if (err == null && _room != null) err = await n.setArea(ieee, _room);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      zbToast(context, err, error: true);
      return;
    }
    setState(() => _phase = _Phase.done);
  }

  Future<void> _pickVia() async {
    final routers = [
      for (final v in ref.read(zigbeeViewsProvider))
        if (v.device.isRouter) v,
    ];
    const auto = '__auto__';
    final choice = await showZbSheet<String>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Über welches Gerät?',
            style: HavenText.headline.copyWith(color: ctx.hv.tx),
          ),
          const SizedBox(height: 4),
          Text(
            'Das neue Gerät verbindet sich mit diesem Router. Wähle ein Gerät in der Nähe des neuen.',
            style: HavenText.body.copyWith(color: ctx.hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 14),
          ZbChoiceRow(
            label: 'Automatisch',
            detail: 'Alle Router im Netz',
            selected: _via == null,
            onTap: () => Navigator.of(ctx).pop(auto),
          ),
          for (final r in routers)
            ZbChoiceRow(
              label: r.name,
              detail: r.roomName ?? 'Kein Raum',
              selected: _via == r.ieee,
              onTap: () => Navigator.of(ctx).pop(r.ieee),
            ),
        ],
      ),
    );
    if (choice == null) return;
    final next = choice == auto ? null : choice;
    if (next == _via) return;
    setState(() => _via = next);
    if (_phase == _Phase.searching) await _openNetwork();
  }

  // ---- Bau ----

  int get _step => switch (_phase) {
    _Phase.explain => 0,
    _Phase.searching || _Phase.timeout => 1,
    _Phase.interview || _Phase.failed => 2,
    _Phase.naming => 3,
    _Phase.done => 4,
  };

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: _phase == _Phase.done
                        ? Icons.close_rounded
                        : Icons.arrow_back_rounded,
                    label: _phase == _Phase.done ? 'Schließen' : 'Zurück',
                    onTap: _close,
                  ),
                  Expanded(child: _Dots(step: _step, count: 5)),
                  const SizedBox(width: HavenSpace.touch),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: context.motion(HavenMotion.d3),
                switchInCurve: HavenMotion.out,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0.08, 0),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_phase),
                  child: _page(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/zigbee');
    }
  }

  Widget _page(BuildContext context) => switch (_phase) {
    _Phase.explain => _explain(context),
    _Phase.searching => _searchPage(context),
    _Phase.timeout => _messagePage(
      context,
      icon: Icons.search_off_rounded,
      title: 'Nichts gefunden',
      text: 'In 4 Minuten hat sich kein Gerät gemeldet. Prüfe, ob das Gerät wirklich blinkt, und rücke näher an einen Router heran.',
      action: 'Nochmal suchen',
      onAction: _startSearch,
    ),
    _Phase.interview => _interviewPage(context),
    _Phase.failed => _messagePage(
      context,
      icon: Icons.error_outline_rounded,
      title: 'Das hat nicht geklappt',
      text: _error ?? 'Unbekannter Fehler.',
      action: 'Nochmal versuchen',
      onAction: () => setState(() => _phase = _Phase.explain),
    ),
    _Phase.naming => _namingPage(context),
    _Phase.done => _donePage(context),
  };

  Widget _frame({
    required List<Widget> children,
    Widget? bottom,
    CrossAxisAlignment align = CrossAxisAlignment.center,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            HavenSpace.page,
            8,
            HavenSpace.page,
            16,
          ),
          children: [Column(crossAxisAlignment: align, children: children)],
        ),
      ),
      if (bottom != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HavenSpace.page,
            0,
            HavenSpace.page,
            16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [bottom],
          ),
        ),
    ],
  );

  // 1 Erklärung
  Widget _explain(BuildContext context) {
    final hv = context.hv;
    final (type, title, text) = switch (_kind) {
      'sensor' => (
        ZbType.climate,
        'Sensor oder Taster',
        'Halte die Anlerntaste am Gerät etwa fünf Sekunden gedrückt, bis die kleine LED blinkt. Bei vielen Sensoren sitzt sie im Batteriefach oder an der Seite.',
      ),
      'plug' => (
        ZbType.plug,
        'Steckdose',
        'Stecke sie ein und halte die Taste an der Steckdose etwa fünf Sekunden gedrückt, bis die LED blinkt.',
      ),
      _ => (
        ZbType.light,
        'Lampe',
        'Schalte die Lampe fünfmal kurz aus und an. Bei den meisten Lampen blinkt oder flackert sie, wenn sie bereit ist.',
      ),
    };
    return _frame(
      bottom: HavenButton(
        label: 'Suche starten',
        icon: Icons.search_rounded,
        primary: true,
        onTap: _startSearch,
      ),
      children: [
        const SizedBox(height: 8),
        Text(
          'Gerät hinzufügen',
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 28),
        ),
        const SizedBox(height: 6),
        Text(
          'Bring das Gerät erst in den Kopplungsmodus, dann startest du die Suche.',
          textAlign: TextAlign.center,
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 18),
        HavenSegmented<String>(
          options: const [
            ('lamp', 'Lampe'),
            ('sensor', 'Sensor'),
            ('plug', 'Steckdose'),
          ],
          selected: _kind,
          onChanged: (k) => setState(() => _kind = k),
        ),
        const SizedBox(height: 22),
        AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            // Fünf Impulse in der ersten Hälfte, dann Pause.
            final t = _anim.value;
            final pulse = context.reduceMotion ? 0.0 : (t * 10);
            final count = context.reduceMotion
                ? 5
                : (t < 0.5 ? pulse.floor() + 1 : 5).clamp(0, 5);
            final on = !context.reduceMotion && t < 0.5 && (pulse % 1) < 0.55;
            return Column(
              children: [
                SizedBox(
                  height: 170,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: Container(
                          width: 168,
                          height: 168,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                hv.acc.withValues(alpha: 0.35),
                                hv.acc.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      ZbDeviceIcon(
                        type: type,
                        size: 130,
                        active: on || context.reduceMotion,
                        tint: _kind == 'lamp'
                            ? const Color(0xFFFFC46B)
                            : hv.acc,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 5; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < count ? hv.acc : hv.s3,
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 22),
        HavenCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: HavenText.headline.copyWith(color: hv.tx)),
              const SizedBox(height: 6),
              Text(
                text,
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
              ),
              const SizedBox(height: 10),
              Text(
                'Danach hast du 4 Minuten Zeit. Ein Gerät in der Nähe eines Routers verbindet sich am zuverlässigsten.',
                style: HavenText.caption.copyWith(color: hv.tx3),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 2 Suche
  Widget _searchPage(BuildContext context) {
    final hv = context.hv;
    final mm = _remaining ~/ 60;
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    final via = _via == null
        ? 'Alle Router'
        : ref.read(zigbeeViewProvider(_via!))?.name ?? 'Router';
    return _frame(
      bottom: HavenButton(label: 'Abbrechen', onTap: _close),
      children: [
        const SizedBox(height: 8),
        SizedBox(
          width: 280,
          height: 280,
          child: AnimatedBuilder(
            animation: _anim,
            builder: (context, _) => CustomPaint(
              painter: _RadarPainter(
                t: context.reduceMotion ? 0.5 : _anim.value,
                progress: _remaining / _kSearchSeconds,
                color: hv.acc,
                track: hv.s3,
              ),
              child: Center(
                child: Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [hv.acc, hv.acc2],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: hv.acc.withValues(alpha: 0.4),
                        blurRadius: 28,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.hub_rounded, color: hv.ai, size: 30),
                      const SizedBox(height: 2),
                      Text(
                        '$mm:$ss',
                        style: HavenText.headline.copyWith(
                          color: hv.ai,
                          fontSize: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Suche läuft',
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 26),
        ),
        const SizedBox(height: 6),
        Text(
          'Das Gerät sollte jetzt blinken. Sobald es sich meldet, geht es hier automatisch weiter.',
          textAlign: TextAlign.center,
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 22),
        PressScale(
          onTap: _pickVia,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: hv.s1,
              borderRadius: BorderRadius.circular(HavenRadii.m),
              border: Border.all(color: hv.ln),
            ),
            child: Row(
              children: [
                Icon(Icons.router_outlined, color: hv.tx2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Verbinden über',
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                      Text(
                        via,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.label.copyWith(color: hv.tx),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.unfold_more_rounded, color: hv.tx3),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 3 Interview
  Widget _interviewPage(BuildContext context) {
    final hv = context.hv;
    final steps = [
      ('Verbindung aufgebaut', _joined),
      ('Gerät erkannt', _started),
      ('Funktionen eingerichtet', _recognized),
    ];
    return _frame(
      children: [
        const SizedBox(height: 24),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.3, end: 1),
          duration: context.motion(HavenMotion.d4),
          curve: HavenMotion.spring,
          builder: (context, s, child) => Opacity(
            opacity: s.clamp(0.0, 1.0),
            child: Transform.scale(scale: s, child: child),
          ),
          child: ZbPulsingIcon(
            type: _recognized ? _typeOfFound() : ZbType.unknown,
            size: 150,
            active: !_recognized,
            tint: hv.acc,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _recognized ? 'Gefunden' : 'Neues Gerät gefunden',
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 26),
        ),
        const SizedBox(height: 6),
        Text(
          _model ?? 'Haven richtet es gerade ein. Das dauert meist ein paar Sekunden.',
          textAlign: TextAlign.center,
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 24),
        for (final (label, done) in steps) _CheckRow(label: label, done: done),
      ],
    );
  }

  String _typeOfFound() {
    final v = _ieee == null ? null : ref.read(zigbeeViewProvider(_ieee!));
    return v?.type ?? ZbType.climate;
  }

  // 4 Name und Raum
  Widget _namingPage(BuildContext context) {
    final hv = context.hv;
    final rooms = ref.watch(roomsProvider);
    return _frame(
      align: CrossAxisAlignment.start,
      bottom: HavenButton(
        label: 'Hinzufügen',
        primary: true,
        busy: _saving,
        onTap: _name.text.trim().isEmpty ? null : _save,
      ),
      children: [
        const SizedBox(height: 8),
        Text(
          'Name und Raum',
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 28),
        ),
        if (_model != null) ...[
          const SizedBox(height: 4),
          Text(_model!, style: HavenText.body.copyWith(color: hv.tx2)),
        ],
        const SizedBox(height: 18),
        NameField(
          controller: _name,
          hint: 'Name',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 22),
        const SectionHeader('Raum'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in rooms)
              _RoomChoice(
                label: r.name,
                on: _room == r.id,
                onTap: () => setState(() {
                  _room = r.id;
                  _roomTouched = true;
                }),
              ),
            _RoomChoice(
              label: 'Kein Raum',
              on: _roomTouched && _room == null,
              onTap: () => setState(() {
                _room = null;
                _roomTouched = true;
              }),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Den Raum kannst du später jederzeit ändern.',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
      ],
    );
  }

  // 5 Fertig
  Widget _donePage(BuildContext context) {
    final hv = context.hv;
    final v = _ieee == null ? null : ref.watch(zigbeeViewProvider(_ieee!));
    return _frame(
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HavenButton(label: 'Fertig', primary: true, onTap: _close),
          const SizedBox(height: 4),
          TextLink(
            'Noch ein Gerät hinzufügen',
            onTap: () => setState(() => _phase = _Phase.explain),
          ),
        ],
      ),
      children: [
        const SizedBox(height: 16),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: hv.ok, shape: BoxShape.circle),
          child: const Icon(
            Icons.check_rounded,
            color: Color(0xFFFFFFFF),
            size: 40,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          v == null ? 'Fertig' : '${v.name} ist bereit',
          textAlign: TextAlign.center,
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 26),
        ),
        const SizedBox(height: 6),
        Text(
          v?.roomName == null
              ? 'Es ist keinem Raum zugeordnet.'
              : 'Es ist im Raum ${v!.roomName}.',
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 22),
        if (v != null) ZbMainFunction(view: v, compact: true),
      ],
    );
  }

  Widget _messagePage(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String text,
    required String action,
    required VoidCallback onAction,
  }) {
    final hv = context.hv;
    return _frame(
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HavenButton(label: action, primary: true, onTap: onAction),
          const SizedBox(height: 8),
          HavenButton(label: 'Abbrechen', onTap: _close),
        ],
      ),
      children: [
        const SizedBox(height: 56),
        Icon(icon, size: 64, color: hv.tx3),
        const SizedBox(height: 16),
        Text(
          title,
          style: HavenText.title.copyWith(color: hv.tx, fontSize: 26),
        ),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
      ],
    );
  }
}

// ---- Teile ----------------------------------------------------------------------

class _Dots extends StatelessWidget {
  const _Dots({required this.step, required this.count});
  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: context.motion(HavenMotion.d3),
            curve: HavenMotion.spring,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == step ? 22 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i <= step ? hv.acc : hv.s3,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.done});
  final String label;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      child: Row(
        children: [
          AnimatedContainer(
            duration: context.motion(HavenMotion.d3),
            curve: HavenMotion.spring,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: done ? hv.ok : hv.s2,
              shape: BoxShape.circle,
            ),
            child: AnimatedOpacity(
              opacity: done ? 1 : 0,
              duration: context.motion(HavenMotion.d2),
              child: const Icon(
                Icons.check_rounded,
                size: 16,
                color: Color(0xFFFFFFFF),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: HavenText.label.copyWith(
                color: done ? hv.tx : hv.tx2,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomChoice extends StatelessWidget {
  const _RoomChoice({
    required this.label,
    required this.on,
    required this.onTap,
  });
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      selected: on,
      child: PressScale(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          constraints: const BoxConstraints(minHeight: HavenSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? hv.tx : hv.s2,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: on ? hv.tx : hv.ln),
          ),
          child: Text(
            label,
            style: HavenText.label.copyWith(color: on ? hv.bg : hv.tx2),
          ),
        ),
      ),
    );
  }
}

/// Radar: drei auslaufende Ringe und ein Bogen mit der Restzeit.
class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.t,
    required this.progress,
    required this.color,
    required this.track,
  });
  final double t;
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t * 1.75 + i / 3) % 1;
      canvas.drawCircle(
        c,
        r * (0.4 + 0.6 * p),
        Paint()
          ..color = color.withValues(alpha: 0.5 * (1 - p))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final ring = Rect.fromCircle(center: c, radius: r - 8);
    canvas.drawArc(
      ring,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    canvas.drawArc(
      ring,
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.t != t || old.progress != progress || old.color != color;
}
