/// Schaltet die Entwicklungsdaten ein: `--dart-define=HAVEN_FAKE=true`.
///
/// Eine `const`-Umgebungsvariable, damit der Compiler im Release-Build den
/// gesamten Code unter `lib/dev/` als unerreichbar entfernt.
const bool kHavenFake = bool.fromEnvironment('HAVEN_FAKE');
