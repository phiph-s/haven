import 'package:flutter_test/flutter_test.dart';
import 'package:haven/features/ha_web/ha_auth_bridge.dart';

void main() {
  test('parst getExternalAuth mit Callback', () {
    final m = parseExternalAuthMessage(
      '{"type":"getExternalAuth","payload":"{\\"callback\\":\\"externalAuthSetToken\\",\\"force\\":true}"}',
    )!;
    expect(m.kind, ExternalAuthKind.get);
    expect(m.callback, 'externalAuthSetToken');
    expect(m.force, isTrue);
  });
  test('Müll ergibt null', () {
    expect(parseExternalAuthMessage('kein json'), isNull);
  });
  test('Callback-Name wird geprüft', () {
    expect(authSuccessJs('x(); evil', 't'), isNull);
    expect(
      authSuccessJs('externalAuthSetToken', 'abc'),
      'externalAuthSetToken(true, {"access_token":"abc","expires_in":1800});',
    );
  });
  test('Ziel-URL hängt external_auth an', () {
    expect(
      haTargetUri(
        'http://ha.local:8123/',
        '/config/automation/edit/42',
      ).toString(),
      'http://ha.local:8123/config/automation/edit/42?external_auth=1',
    );
    expect(haTargetUri('ha.local:8123', '/').host, 'ha.local');
  });
}
