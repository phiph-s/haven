/// Qualitätsstufen der 3D-Ansicht für schwächere Geräte.
///
/// Jede Stufe dreht an denselben Stellschrauben; die teuersten zuerst:
///
/// | Stellschraube | Hoch | Mittel | Niedrig |
/// |---|---|---|---|
/// | Pixeldichte des Renderziels | Gerät | höchstens 1,5 | 1,0 |
/// | Kantenglättung | MSAA | FXAA | FXAA |
/// | Bildrate (Obergrenze) | Bildschirm | 60 | 30 |
/// | Lampenlicht in Echtzeit (Wände, Möbelseiten) | an | an | aus |
/// | Raster des gebakenen Lampenlichts | 5 cm | 7 cm | 10 cm |
/// | Strahlen je Texel (weiche Schatten von Sonne und Lampen) | 7 | 5 | 3 |
///
/// Schatten gibt es nur gebaken (Böden und Oberseiten), in Echtzeit keine.
/// Unabhängig von der Stufe rendert die Ansicht nur, solange sich etwas
/// bewegt (Kamera, Animation, Lampen); danach steht das Bild ohne Kosten.
enum SceneQuality {
  low('Niedrig'),
  medium('Mittel'),
  high('Hoch'),

  /// Für Editoren: kein Baking (Böden und Oberseiten im Echtzeitlicht der
  /// Sonne), damit ein Neuaufbau nach jeder Änderung schnell geht.
  draft('Entwurf'),

  /// Wie [draft], aber Lampen leuchten in Echtzeit (Editor mit Licht).
  draftLit('Entwurf mit Licht');

  const SceneQuality(this.label);
  final String label;

  /// Größte Pixeldichte des Renderziels (null: wie das Gerät).
  double? get maxPixelRatio => switch (this) {
    low => 1.0,
    medium || draft || draftLit => 1.5,
    high => null,
  };

  /// MSAA statt FXAA.
  bool get msaa => this == high;

  /// Obergrenze der Bildrate (null: Bildschirmrate).
  double? get maxFrameRate => switch (this) {
    low => 30,
    medium || draft || draftLit => 60,
    high => null,
  };

  bool get realtimeLamps => this != low && this != draft;

  /// Licht auf Böden und Oberseiten backen (alle Stufen außer [draft]).
  bool get bakes => this != draft && this != draftLit;

  double get bakeTexel => switch (this) {
    low => 0.10,
    medium => 0.07,
    high => 0.05,
    draft || draftLit => 0.25,
  };

  int get bakeSamples => switch (this) {
    low => 3,
    medium => 5,
    high => 7,
    draft || draftLit => 0,
  };
}
