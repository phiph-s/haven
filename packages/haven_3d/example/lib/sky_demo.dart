import 'dart:async';

import 'package:haven_3d/haven_3d.dart';
import 'package:material_ui/material_ui.dart';

/// Testszene für Tag und Nacht: Uhrzeit, Jahreszeit, Mondphase, Wetter und
/// Lage der Wohnung. Sonne und Mond scheinen durch die Fenster, Schatten in
/// Echtzeit. Aufruf: Knopf „Tag & Nacht“ oder `?sky` in der Adresse.
class SkyDemoPage extends StatefulWidget {
  const SkyDemoPage({super.key});

  @override
  State<SkyDemoPage> createState() => _SkyDemoPageState();
}

class _SkyDemoPageState extends State<SkyDemoPage> {
  final Scene _scene = sampleScene();
  final SceneController _cam = SceneController(
    const OrbitCamera(yaw: -0.5, pitch: 0.95),
  );

  /// Grundfläche der Wohnung (Wolken ziehen um sie herum).
  late final Rect _extent = () {
    final pts = [for (final r in _scene.rooms) ...r.outline];
    var r = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }();

  /// Mitte der Wohnung (für die Lage von Sonne und Mond).
  late final V3 _center = () {
    final pts = [for (final r in _scene.rooms) ...r.outline];
    var x = 0.0, y = 0.0;
    for (final p in pts) {
      x += p.dx;
      y += p.dy;
    }
    return V3(x / pts.length, y / pts.length, 0);
  }();

  double _hour = 15.5;
  double _day = 300; // Ende Oktober
  double _moon = 0.5;
  double _cloud = 0;
  double _rain = 0;
  double _snowfall = 0;
  double _snowDepth = 0; // cm
  double _storm = 0;
  double _north = 0;
  bool _lamps = false;
  _Look _look = _Look.light;
  Timer? _play;

  SceneSky get _sky => SceneSky.at(
    dayOfYear: _day.round(),
    hour: _hour,
    moonPhase: _moon,
    cloud: _cloud,
    rain: _rain,
    snow: _snowfall,
    storm: _storm,
    north: _north,
  );

  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void dispose() {
    _play?.cancel();
    super.dispose();
  }

  void _apply() {
    _cam.setSky(_sky);
    // Kein Rasen: der Boden ist unsichtbar und trägt nur den Schnee (ab
    // etwa 25 cm eine geschlossene Decke).
    _cam.setGround(
      SceneGround(
        color: const Color(0x00FFFFFF),
        snow: (_snowDepth / 25).clamp(0.0, 1.0),
      ),
    );
    for (final m in _scene.markers) {
      if (m.lamp == null) continue;
      _cam.setLamp(
        m.id,
        _lamps
            ? const LampState(brightness: 0.8, color: Color(0xFFFFC489))
            : LampState.off,
      );
    }
  }

  void _set(VoidCallback f) {
    setState(f);
    _apply();
  }

  void _togglePlay() {
    if (_play != null) {
      _play!.cancel();
      setState(() => _play = null);
      return;
    }
    // Eine Stunde je Sekunde.
    _play = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _set(() => _hour = (_hour + 0.05) % 24);
    });
    setState(() {});
  }

  static String _hm(double h) {
    final m = (h * 60).round() % (24 * 60);
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ];

  static String _date(int day) {
    final d = DateTime(2026).add(Duration(days: day - 1));
    return '${d.day}. ${_months[d.month - 1]}';
  }

  static String _compass(double az) {
    const names = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return names[((az % 360) / 45).round() % 8];
  }

  static String _moonName(double p) {
    if (p < 0.04 || p > 0.96) return 'Neumond';
    if ((p - 0.5).abs() < 0.04) return 'Vollmond';
    if ((p - 0.25).abs() < 0.04) return 'erstes Viertel';
    if ((p - 0.75).abs() < 0.04) return 'letztes Viertel';
    return p < 0.5 ? 'zunehmend' : 'abnehmend';
  }

  Widget _slider(
    String label,
    String value,
    double v,
    double min,
    double max,
    ValueChanged<double> on, {
    int? divisions,
  }) => Row(
    children: [
      SizedBox(width: 92, child: Text(label)),
      Expanded(
        child: Slider(
          value: v.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: on,
        ),
      ),
      SizedBox(width: 120, child: Text(value, textAlign: TextAlign.right)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final sky = _sky;
    final light = sky.light;
    // Hintergrund nach Tageszeit: blauer Himmel, Dämmerung, Nacht.
    final dayT = ((sky.sunElevation + 8) / 20).clamp(0.0, 1.0);
    final top = Color.lerp(
      const Color(0xFF0B1020),
      Color.lerp(const Color(0xFF8DB7E8), const Color(0xFFB7C0CA), _cloud)!,
      dayT,
    )!;
    // Hell und dunkel unterscheiden sich nur im Verlauf: oben der Himmel
    // nach Tageszeit, unten weiß bzw. schwarz. Licht und Wohnung bleiben
    // gleich.
    final dark = _look == _Look.dark;
    final bg = [
      top,
      if (dark) const Color(0xFF07080B) else const Color(0xFFF4F3F0),
    ];
    final style = SceneStyle.light();
    final ink = dark || dayT < 0.5 ? Colors.white : Colors.black87;
    final status =
        'Sonne ${sky.sunElevation.toStringAsFixed(0)}° ${_compass(sky.sunAzimuth)} · '
        'Mond ${sky.moonElevation.toStringAsFixed(0)}° ${_compass(sky.moonAzimuth)}, '
        '${(sky.moonIllumination * 100).round()} % · '
        '${light.night ? 'Mondlicht' : 'Sonnenlicht'} '
        '${(light.intensity * 100).toStringAsFixed(light.intensity < 0.1 ? 1 : 0)} %';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tag & Nacht'),
        actions: [
          IconButton(
            tooltip: _play == null ? 'Zeit laufen lassen' : 'Anhalten',
            icon: Icon(_play == null ? Icons.play_arrow : Icons.pause),
            onPressed: _togglePlay,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: bg,
                      ),
                    ),
                    child: SkyLayers(
                      sky: sky,
                      controller: _cam,
                      center: _center,
                      extent: _extent,
                      child: Scene3DView(
                        scene: _scene,
                        controller: _cam,
                        style: style,
                        quality: SceneQuality.medium,
                        showStats: true,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 10,
                  right: 12,
                  child: Text(status, style: TextStyle(color: ink)),
                ),
              ],
            ),
          ),
          Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _slider(
                        'Uhrzeit',
                        _hm(_hour),
                        _hour,
                        0,
                        24,
                        (v) => _set(() => _hour = v),
                      ),
                      _slider(
                        'Jahreszeit',
                        _date(_day.round()),
                        _day,
                        1,
                        365,
                        (v) => _set(() => _day = v),
                      ),
                      _slider(
                        'Mond',
                        _moonName(_moon),
                        _moon,
                        0,
                        1,
                        (v) => _set(() => _moon = v),
                      ),
                      _slider(
                        'Bewölkung',
                        _cloud < 0.1
                            ? 'klar'
                            : _cloud > 0.85
                            ? 'bedeckt'
                            : '${(_cloud * 100).round()} %',
                        _cloud,
                        0,
                        1,
                        (v) => _set(() => _cloud = v),
                      ),
                      _slider(
                        'Regen',
                        _rain < 0.05
                            ? 'kein'
                            : _rain < 0.4
                            ? 'leicht'
                            : _rain < 0.75
                            ? 'mittel'
                            : 'stark',
                        _rain,
                        0,
                        1,
                        (v) => _set(() => _rain = v),
                      ),
                      _slider(
                        'Schneefall',
                        _snowfall < 0.05
                            ? 'keiner'
                            : _snowfall < 0.5
                            ? 'leicht'
                            : 'dicht',
                        _snowfall,
                        0,
                        1,
                        (v) => _set(() => _snowfall = v),
                      ),
                      _slider(
                        'Schneehöhe',
                        '${_snowDepth.round()} cm',
                        _snowDepth,
                        0,
                        40,
                        (v) => _set(() => _snowDepth = v),
                      ),
                      _slider(
                        'Gewitter',
                        _storm < 0.05
                            ? 'keins'
                            : _storm < 0.6
                            ? 'fern'
                            : 'heftig',
                        _storm,
                        0,
                        1,
                        (v) => _set(() => _storm = v),
                      ),
                      _slider(
                        'Norden',
                        '${_north.round()}°',
                        _north,
                        0,
                        345,
                        (v) => _set(() => _north = v),
                        divisions: 23,
                      ),
                      Row(
                        children: [
                          SegmentedButton<_Look>(
                            segments: [
                              for (final l in _Look.values)
                                ButtonSegment(value: l, label: Text(l.label)),
                            ],
                            selected: {_look},
                            onSelectionChanged: (v) =>
                                _set(() => _look = v.first),
                          ),
                          const SizedBox(width: 12),
                          FilterChip(
                            label: const Text('Lampen an'),
                            selected: _lamps,
                            onSelected: (v) => _set(() => _lamps = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helles oder dunkles Design: Himmel oben, unten weiß bzw. schwarz.
enum _Look {
  light('Hell'),
  dark('Dunkel');

  const _Look(this.label);
  final String label;
}
