import 'dart:math' as math;

import 'package:haven_3d/haven_3d.dart';
import 'package:material_ui/material_ui.dart';

import 'sky_demo.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  bool _dark = true;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Haven 3D',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: _dark ? Brightness.dark : Brightness.light),
    // `?sky` öffnet gleich die Testszene für Tag und Nacht.
    home: Uri.base.queryParameters.containsKey('sky')
        ? const SkyDemoPage()
        : DemoPage(dark: _dark, onDark: (v) => setState(() => _dark = v)),
  );
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key, required this.dark, required this.onDark});

  final bool dark;
  final ValueChanged<bool> onDark;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final Scene _scene = sampleScene();
  final SceneController _cam = SceneController();
  String? _room;
  bool _lampOn = true;

  /// Räume in 3D (null: alle). Tippen stellt einen Raum auf, die übrigen
  /// liegen flach.
  Set<String>? _raised;

  String? _roomOfHit(SceneHit h) => switch (h.kind) {
    HitKind.room => h.id,
    HitKind.object => _scene.objectRoom[h.id],
    HitKind.marker => _scene.markerRoom[h.id],
  };
  double _edge = 2.5;
  bool _perspective = false;
  bool _sun = true;
  bool _stats = true;
  SceneQuality _quality = SceneQuality.high;
  SceneHit? _hit;

  /// Kartenart: Licht (gebaken) oder eine Heatmap.
  _MapMode _mode = _MapMode.light;

  /// Gerät oder Möbelstück im Detail-Panel (Kamera ist hingefahren).
  SceneHit? _detail;
  Set<String>? _raisedBefore;
  double _mapHeight = 0;

  late final Map<String, List<HeatPoint>> _temps = _fakeHeat(const {
    'wohnen': [21.6, 20.9],
    'kueche': [22.8, 21.1],
    'bad': [23.4],
    'flur': [19.6],
    'schlafen': [18.4, 18.9],
    'arbeiten': [21.0, 20.1],
  });
  late final Map<String, List<HeatPoint>> _humidity = _fakeHeat(const {
    'wohnen': [46, 44],
    'kueche': [52, 49],
    'bad': [68],
    'flur': [45],
    'schlafen': [55, 51],
    'arbeiten': [41, 43],
  });
  late final SceneHeatmap _tempMap = SceneHeatmap.fitted(
    _temps,
    ramp: HeatRamps.temperature,
  );
  late final SceneHeatmap _humidityMap = SceneHeatmap.fitted(
    _humidity,
    ramp: HeatRamps.humidity,
    step: 5,
    minSpan: 20,
  );

  /// Erfundene Messpunkte: je Wert ein Punkt, verteilt um die Raummitte.
  Map<String, List<HeatPoint>> _fakeHeat(Map<String, List<double>> v) => {
    for (final e in v.entries)
      e.key: [
        for (var i = 0; i < e.value.length; i++)
          HeatPoint(
            _scene.room(e.key)!.centroid +
                Offset(i == 0 ? -0.9 : 0.9, i == 0 ? -0.6 : 0.6) *
                    (e.value.length == 1 ? 0 : 1),
            e.value[i],
          ),
      ],
  };

  SceneHeatmap? get _heatmap => switch (_mode) {
    _MapMode.light => null,
    _MapMode.temperature => _tempMap,
    _MapMode.humidity => _humidityMap,
  };

  /// Gerät/Möbel antippen: Raum aufstellen und umranden, Kamera schräg
  /// hinfahren (oberes Drittel), Panel von unten.
  void _openDetail(SceneHit h) {
    final room = _roomOfHit(h);
    setState(() {
      _raisedBefore ??= _raised;
      _detail = h;
      _hit = h;
      if (room != null) _raised = {room};
    });
    _cam.focus(
      markerId: h.kind == HitKind.marker ? h.id : null,
      objectId: h.kind == HitKind.object ? h.id : null,
      roomId: h.kind == HitKind.room ? h.id : null,
      pitch: 0.9,
      insets: EdgeInsets.only(bottom: _mapHeight * 2 / 3),
    );
  }

  void _closeDetail() {
    setState(() {
      _detail = null;
      _hit = null;
      _raised = _raisedBefore;
      _raisedBefore = null;
    });
    _cam.back();
  }

  void _view(({double yaw, double pitch}) v) =>
      _cam.show(roomId: _room, yaw: v.yaw, pitch: v.pitch);

  void _rotate(double deg) => _cam.show(
    roomId: _room,
    yaw: _cam.camera.yaw + deg * math.pi / 180,
    pitch: _cam.camera.pitch,
  );

  void _pickRoom(String? id) {
    setState(() {
      _room = id;
      _hit = null;
    });
    // Ein Raum allein: schräg von der Seite, sonst Draufsicht.
    final v = id == null ? SceneViews.top : SceneViews.iso;
    _cam.show(roomId: id, yaw: v.yaw, pitch: v.pitch);
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.dark ? SceneStyle.dark() : SceneStyle.light();
    // Übersicht: Wände halb durchsichtig, damit man in die Räume sieht.
    final style = base.copyWith(
      wallOpacity: _room == null ? base.wallOpacity : base.wallOpacity + 0.3,
      // Regler: Mindestbreite in Pixeln, Weltbreite im selben Verhältnis.
      edgeWidth: _edge,
      sun: _sun ? base.sun : 0,
      edgeWorldWidth: base.edgeWorldWidth * _edge / base.edgeWidth,
    );
    final hit = _hit;
    // Verlauf wie hinter der Haven-Karte: das 3D-Bild ist durchsichtig.
    final bg = widget.dark
        ? const [Color(0xFF2A2117), Color(0xFF15171B), Color(0xFF101114)]
        : const [Color(0xFFF3EEE6), Color(0xFFF1F1EF), Color(0xFFE4E7EA)];
    final text = widget.dark
        ? const Color(0xFFB4B8C0)
        : const Color(0xFF55575C);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String?>(
                      value: _room,
                      hint: const Text('Ganze Wohnung'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Ganze Wohnung'),
                        ),
                        for (final r in _scene.rooms)
                          DropdownMenuItem(value: r.id, child: Text(r.id)),
                      ],
                      onChanged: _pickRoom,
                    ),
                    OutlinedButton(
                      onPressed: () => _view(SceneViews.top),
                      child: const Text('Draufsicht'),
                    ),
                    OutlinedButton(
                      onPressed: () => _view(SceneViews.iso),
                      child: const Text('Schräg'),
                    ),
                    OutlinedButton(
                      onPressed: () => _view(SceneViews.side),
                      child: const Text('Seite'),
                    ),
                    IconButton(
                      tooltip: 'Links drehen',
                      onPressed: () => _rotate(-45),
                      icon: const Icon(Icons.rotate_left),
                    ),
                    IconButton(
                      tooltip: 'Rechts drehen',
                      onPressed: () => _rotate(45),
                      icon: const Icon(Icons.rotate_right),
                    ),
                    SegmentedButton<_MapMode>(
                      segments: [
                        for (final m in _MapMode.values)
                          ButtonSegment(value: m, label: Text(m.label)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (v) =>
                          setState(() => _mode = v.first),
                    ),
                    FilterChip(
                      label: const Text('Sonne'),
                      selected: _sun,
                      onSelected: (v) => setState(() => _sun = v),
                    ),
                    FilterChip(
                      label: const Text('Perspektive'),
                      selected: _perspective,
                      onSelected: (v) {
                        setState(() => _perspective = v);
                        _cam.setPerspective(v);
                      },
                    ),
                    DropdownButton<SceneQuality>(
                      value: _quality,
                      items: [
                        for (final q in SceneQuality.values)
                          DropdownMenuItem(value: q, child: Text(q.label)),
                      ],
                      onChanged: (q) => setState(() => _quality = q!),
                    ),
                    FilterChip(
                      label: const Text('FPS'),
                      selected: _stats,
                      onSelected: (v) => setState(() => _stats = v),
                    ),
                    FilterChip(
                      label: const Text('Alle 3D'),
                      selected: _raised == null,
                      onSelected: (v) =>
                          setState(() => _raised = v ? null : {}),
                    ),
                    FilterChip(
                      label: const Text('Licht Wohnen'),
                      selected: _lampOn,
                      onSelected: (v) {
                        setState(() => _lampOn = v);
                        _cam.setLamp(
                          'licht_wohnen',
                          v ? const LampState() : LampState.off,
                        );
                      },
                    ),
                    SizedBox(
                      width: 230,
                      child: Row(
                        children: [
                          Text('Kanten', style: TextStyle(color: text)),
                          Expanded(
                            child: Slider(
                              value: _edge,
                              min: 0.5,
                              max: 4,
                              onChanged: (v) => setState(() => _edge = v),
                            ),
                          ),
                          Text(
                            '${_edge.toStringAsFixed(1)} px',
                            style: TextStyle(color: text, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    FilterChip(
                      label: const Text('Dunkel'),
                      selected: widget.dark,
                      onSelected: widget.onDark,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.wb_twilight, size: 18),
                      label: const Text('Tag & Nacht'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SkyDemoPage(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    _mapHeight = box.maxHeight;
                    final detail = _detail;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Scene3DView(
                            scene: _scene,
                            controller: _cam,
                            style: style,
                            focusRoomId: _room,
                            selected: {?hit?.id},
                            raisedRooms: _raised,
                            quality: _quality,
                            showStats: _stats,
                            selectedRoomId: detail == null
                                ? null
                                : _roomOfHit(detail),
                            heatmap: _heatmap,
                            onTap: (h) {
                              if (h == null) return;
                              if (h.kind == HitKind.room) {
                                // Raum antippen: aufstellen, die übrigen flach.
                                setState(() {
                                  _hit = h;
                                  _raised = {h.id};
                                });
                                return;
                              }
                              _openDetail(h);
                            },
                          ),
                        ),
                        _DetailPanel(
                          hit: detail,
                          height: box.maxHeight * 2 / 3,
                          room: detail == null ? null : _roomOfHit(detail),
                          lamp: detail?.kind == HitKind.marker
                              ? _scene.markers
                                    .firstWhere((m) => m.id == detail!.id)
                                    .lamp
                              : null,
                          onLamp: (s) => _cam.setLamp(detail!.id, s),
                          onClose: _closeDetail,
                          dark: widget.dark,
                        ),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  hit == null
                      ? 'Ziehen dreht · Umschalt+Ziehen oder zwei Finger verschieben · Mausrad zoomt'
                      : switch (hit.kind) {
                          HitKind.marker => 'Gerät: ${hit.id}',
                          HitKind.object => 'Möbel: ${hit.id}',
                          HitKind.room => 'Raum: ${hit.id}',
                        },
                  style: TextStyle(color: text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MapMode {
  light('Licht'),
  temperature('Temperatur'),
  humidity('Luftfeuchte');

  const _MapMode(this.label);
  final String label;
}

/// Detail-Panel über die unteren zwei Drittel: fährt hoch, wenn ein Gerät
/// gewählt ist. Für Leuchten mit Schalter und Helligkeit.
class _DetailPanel extends StatefulWidget {
  const _DetailPanel({
    required this.hit,
    required this.height,
    required this.room,
    required this.lamp,
    required this.onLamp,
    required this.onClose,
    required this.dark,
  });

  final SceneHit? hit;
  final double height;
  final String? room;
  final LampState? lamp;
  final ValueChanged<LampState> onLamp;
  final VoidCallback onClose;
  final bool dark;

  @override
  State<_DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<_DetailPanel> {
  SceneHit? _shown;
  LampState? _lamp;

  @override
  void didUpdateWidget(_DetailPanel old) {
    super.didUpdateWidget(old);
    if (widget.hit != null && widget.hit != _shown) {
      _shown = widget.hit;
      _lamp = widget.lamp;
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.hit != null;
    final bg = widget.dark ? const Color(0xF21B1D22) : const Color(0xF2FFFFFF);
    final fg = widget.dark ? const Color(0xFFE6E8EB) : const Color(0xFF2B2E33);
    final hit = _shown;
    final lamp = _lamp;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      left: 0,
      right: 0,
      height: widget.height,
      bottom: open ? 0 : -widget.height - 20,
      child: Material(
        color: bg,
        elevation: 12,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: hit == null
            ? const SizedBox()
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: DefaultTextStyle(
                  style: TextStyle(color: fg, fontSize: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Zurück',
                            onPressed: widget.onClose,
                            icon: Icon(Icons.arrow_back, color: fg),
                          ),
                          Expanded(
                            child: Text(
                              hit.id,
                              style: TextStyle(
                                color: fg,
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${hit.kind == HitKind.marker ? 'Gerät' : 'Möbel'}'
                        ' · Raum ${widget.room ?? '–'}',
                      ),
                      const SizedBox(height: 16),
                      if (lamp != null) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('Licht', style: TextStyle(color: fg)),
                          value: lamp.on,
                          onChanged: (v) => _set(
                            LampState(
                              on: v,
                              brightness: lamp.brightness,
                              color: lamp.color,
                            ),
                          ),
                        ),
                        Text('Helligkeit', style: TextStyle(color: fg)),
                        Slider(
                          value: lamp.brightness,
                          onChanged: (v) => _set(
                            LampState(
                              on: lamp.on,
                              brightness: v,
                              color: lamp.color,
                            ),
                          ),
                        ),
                      ] else
                        const Text(
                          'Hier kommen später Details und Steuerung aus der App hin.',
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  void _set(LampState s) {
    setState(() => _lamp = s);
    widget.onLamp(s);
  }
}
