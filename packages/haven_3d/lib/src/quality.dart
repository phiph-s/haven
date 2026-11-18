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
  high('Hoch');

  const SceneQuality(this.label);
  final String label;

  /// Größte Pixeldichte des Renderziels (null: wie das Gerät).
  double? get maxPixelRatio => switch (this) {
    low => 1.0,
    medium => 1.5,
    high => null,
  };

  /// MSAA statt FXAA.
  bool get msaa => this == high;

  /// Obergrenze der Bildrate (null: Bildschirmrate).
  double? get maxFrameRate => switch (this) {
    low => 30,
    medium => 60,
    high => null,
  };

  bool get realtimeLamps => this != low;

  double get bakeTexel => switch (this) {
    low => 0.10,
    medium => 0.07,
    high => 0.05,
  };

  int get bakeSamples => switch (this) {
    low => 3,
    medium => 5,
    high => 7,
  };
}
