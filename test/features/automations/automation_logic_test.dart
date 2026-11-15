import 'package:flutter_test/flutter_test.dart';
import 'package:haven/features/automations/automation_logic.dart';

void main() {
  group('detectRoom', () {
    test('erkennt Räume aus echten Namen', () {
      expect(detectRoom('Bad Licht anschalten'), 'Bad');
      expect(detectRoom('Umschalten Schlafzimmer'), 'Schlafzimmer');
      expect(detectRoom('Licht Wohnzimmer ausschalten'), 'Wohnzimmer');
      expect(detectRoom('Küche Licht an'), 'Küche');
      expect(detectRoom('Bad Ventilator (Sensor > 59%)'), 'Bad');
    });
    test('ohne Raum null', () {
      expect(detectRoom('Nächtlicher Neustart'), isNull);
      expect(detectRoom('Drehknopf: Einfach'), isNull);
      expect(detectRoom(''), isNull);
    });
    test('wortweise: Badewanne ist kein Bad', () {
      expect(detectRoom('Badewanne füllen'), isNull);
    });
    test('Räume der Sitzung haben Vorrang', () {
      expect(detectRoom('Lampe Studio an', ['Studio']), 'Studio');
      expect(detectRoom('Kuche an', ['Küche']), 'Küche');
    });
  });

  group('relativeTime', () {
    final now = DateTime(2026, 11, 15, 12);
    String r(Duration d) => relativeTime(now.subtract(d), now);
    test('Stufen', () {
      expect(relativeTime(null, now), 'noch nie ausgelöst');
      expect(r(const Duration(seconds: 20)), 'gerade eben');
      expect(r(const Duration(minutes: 5)), 'vor 5 Min');
      expect(r(const Duration(hours: 3)), 'vor 3 Std');
      expect(r(const Duration(hours: 30)), 'gestern');
      expect(r(const Duration(days: 4)), 'vor 4 Tagen');
      expect(r(const Duration(days: 21)), 'vor 3 Wochen');
      expect(r(const Duration(days: 90)), 'vor 3 Monaten');
    });
    test('Zukunft zählt als gerade eben', () {
      expect(
        relativeTime(now.add(const Duration(minutes: 2)), now),
        'gerade eben',
      );
    });
  });

  test('prettyName', () {
    expect(prettyName('sun_motion1'), 'Sun motion1');
    expect(prettyName('Bad Ventilator AN'), 'Bad Ventilator AN');
  });

  test('groupByRoom: Räume in Reihenfolge, Allgemein zuletzt', () {
    AutomationItem a(String n, String? room) => AutomationItem(
      entityId: 'automation.$n',
      name: n,
      on: true,
      room: room,
    );
    final g = groupByRoom(
      [a('x', null), a('b', 'Bad'), a('w', 'Salon'), a('a', 'Bad')],
      roomOrder: ['Salon', 'Bad'],
    );
    expect([for (final e in g) e.$1], ['Salon', 'Bad', 'Allgemein']);
    expect([for (final i in g[1].$2) i.name], ['a', 'b']);
  });
}
