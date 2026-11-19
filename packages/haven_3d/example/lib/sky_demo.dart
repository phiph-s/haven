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

  double _hour = 15.5;
  double _day = 300; // Ende Oktober
  double _moon = 0.5;
  double _cloud = 0;
  double _north = 0;
  bool _lamps = false;
  Timer? _play;

  SceneSky get _sky => SceneSky.at(
    dayOfYear: _day.round(),
    hour: _hour,
    moonPhase: _moon,
    cloud: _cloud,
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
    final bottom = Color.lerp(
      const Color(0xFF151A24),
      const Color(0xFFEFEDE8),
      dayT,
    )!;
    final ink = dayT > 0.5 ? Colors.black87 : Colors.white;
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
                        colors: [top, bottom],
                      ),
                    ),
                    child: Scene3DView(
                      scene: _scene,
                      controller: _cam,
                      style: SceneStyle.light().copyWith(cutaway: true),
                      quality: SceneQuality.medium,
                      showStats: true,
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
                    'Norden',
                    '${_north.round()}°',
                    _north,
                    0,
                    345,
                    (v) => _set(() => _north = v),
                    divisions: 23,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      label: const Text('Lampen an'),
                      selected: _lamps,
                      onSelected: (v) => _set(() => _lamps = v),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
