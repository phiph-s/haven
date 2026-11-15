import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/features/updates/app_installer.dart';
import 'package:haven/features/updates/app_release.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _release(
  String tag, {
  bool draft = false,
  bool pre = false,
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'name': 'Haven $tag',
  'draft': draft,
  'prerelease': pre,
  'html_url': 'https://github.com/phiph-s/haven/releases/tag/$tag',
  'body': '## Neu\n\n- Etwas',
  'assets':
      assets ??
      [
        {
          'name': 'haven-${tag.substring(1)}.apk',
          'size': 1234,
          'browser_download_url':
              'https://github.com/phiph-s/haven/releases/download/$tag/haven-${tag.substring(1)}.apk',
        },
      ],
};

void main() {
  group('Versionsvergleich', () {
    test('semantisch statt als Text', () {
      expect(isNewerVersion('0.10.0', '0.9.1'), isTrue);
      expect(isNewerVersion('v1.0.0', '0.99.99'), isTrue);
      expect(isNewerVersion('0.3.0', '0.3.0'), isFalse);
      expect(isNewerVersion('0.2.9', '0.3.0'), isFalse);
      expect(isNewerVersion('0.3.0+5', '0.3.0'), isFalse);
    });

    test('Vorabversion liegt unter der fertigen', () {
      expect(isNewerVersion('0.3.0', '0.3.0-beta.1'), isTrue);
      expect(isNewerVersion('0.3.0-beta.2', '0.3.0-beta.1'), isTrue);
      expect(isNewerVersion('0.3.0-beta.1', '0.3.0'), isFalse);
    });

    test('Unlesbares gilt nie als neuer', () {
      expect(isNewerVersion('latest', '0.3.0'), isFalse);
      expect(isNewerVersion('0.4.0', 'dev'), isFalse);
      expect(SemVer.tryParse(''), isNull);
      expect(SemVer.tryParse('v2')?.toString(), '2.0.0');
    });
  });

  group('Release und Asset', () {
    test('nimmt das Asset haven-<version>.apk', () {
      final r = parseRelease(
        _release(
          'v0.4.0',
          assets: [
            {
              'name': 'notes.txt',
              'browser_download_url': 'https://example.org/notes.txt',
            },
            {
              'name': 'haven-0.4.0.apk',
              'size': 99,
              'browser_download_url': 'https://example.org/haven-0.4.0.apk',
            },
            {
              'name': 'haven-0.3.0.apk',
              'browser_download_url': 'https://example.org/old.apk',
            },
          ],
        ),
      )!;
      expect(r.version, '0.4.0');
      expect(r.apkUrl, 'https://example.org/haven-0.4.0.apk');
      expect(r.apkSize, 99);
      expect(r.notes, contains('Neu'));
    });

    test('einziges anderes APK dient als Ersatz, mehrere nicht', () {
      final one = parseRelease(
        _release(
          'v0.4.0',
          assets: [
            {
              'name': 'app-release.apk',
              'browser_download_url': 'https://example.org/a.apk',
            },
          ],
        ),
      )!;
      expect(one.apkUrl, 'https://example.org/a.apk');
      final two = parseRelease(
        _release(
          'v0.4.0',
          assets: [
            for (final n in ['a.apk', 'b.apk'])
              {'name': n, 'browser_download_url': 'https://example.org/$n'},
          ],
        ),
      )!;
      expect(two.hasApk, isFalse);
    });

    test('Entwurf, Pre-Release und kaputte Tags fallen weg', () {
      expect(parseRelease(_release('v0.4.0', draft: true)), isNull);
      expect(parseRelease(_release('v0.4.0', pre: true)), isNull);
      expect(parseRelease(_release('v0.4.0-rc.1')), isNull);
      expect(parseRelease(_release('nightly')), isNull);
      expect(parseRelease('Quatsch'), isNull);
    });

    test('nur https-Downloads', () {
      final r = parseRelease(
        _release(
          'v0.4.0',
          assets: [
            {
              'name': 'haven-0.4.0.apk',
              'browser_download_url': 'http://example.org/haven-0.4.0.apk',
            },
          ],
        ),
      )!;
      expect(r.hasApk, isFalse);
    });

    test('Ablage und Rückweg', () {
      final r = parseRelease(_release('v0.4.0'))!;
      final back = ReleaseInfo.fromStored(jsonDecode(jsonEncode(r.toJson())));
      expect(back, r);
      expect(ReleaseInfo.fromStored({'x': 1}), isNull);
    });
  });

  group('Intervall', () {
    final now = DateTime(2026, 11, 15, 12);
    test('fällig ohne Prüfung und nach 6 Stunden', () {
      expect(isCheckDue(null, now), isTrue);
      expect(
        isCheckDue(now.subtract(const Duration(hours: 5, minutes: 59)), now),
        isFalse,
      );
      expect(isCheckDue(now.subtract(const Duration(hours: 6)), now), isTrue);
      expect(isCheckDue(now.add(const Duration(hours: 1)), now), isTrue);
    });
  });

  group('ReleaseChecker mit Fake-Client', () {
    test('fragt die API ab und liest das Release', () async {
      late Uri asked;
      final c = ReleaseChecker(
        MockClient((req) async {
          asked = req.url;
          return http.Response(jsonEncode(_release('v0.5.0')), 200);
        }),
      );
      final r = await c.latest(kAppRepo);
      expect(
        asked.toString(),
        'https://api.github.com/repos/phiph-s/haven/releases/latest',
      );
      expect(r?.version, '0.5.0');
    });

    test('404 heißt kein Release, andere Fehler werfen', () async {
      expect(
        await ReleaseChecker(MockClient((_) async => http.Response('', 404)))
            .latest(kAppRepo),
        isNull,
      );
      await expectLater(
        ReleaseChecker(MockClient((_) async => http.Response('', 403)))
            .latest(kAppRepo),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('Download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('haven_dl'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('schreibt die Datei und meldet Fortschritt', () async {
      final bytes = List<int>.generate(5000, (i) => i % 251);
      final client = MockClient.streaming((req, _) async {
        Stream<List<int>> chunks() async* {
          for (var i = 0; i < bytes.length; i += 1000) {
            yield bytes.sublist(i, i + 1000);
          }
        }

        return http.StreamedResponse(
          chunks(),
          200,
          contentLength: bytes.length,
        );
      });
      final seen = <double?>[];
      final f = await downloadFile(
        client,
        Uri.parse('https://example.org/haven-0.4.0.apk'),
        File('${dir.path}/haven-0.4.0.apk'),
        expectedSize: bytes.length,
        onProgress: seen.add,
      );
      expect(await f.readAsBytes(), bytes);
      expect(seen.last, 1.0);
      expect(seen.length, 5);
      expect(File('${f.path}.part').existsSync(), isFalse);
    });

    test('falsche Größe und Fehlercode lassen keine Datei zurück', () async {
      final target = File('${dir.path}/haven-0.4.0.apk');
      final small = MockClient((_) async => http.Response('abc', 200));
      await expectLater(
        downloadFile(
          small,
          Uri.parse('https://example.org/a'),
          target,
          expectedSize: 10,
        ),
        throwsA(isA<http.ClientException>()),
      );
      final bad = MockClient((_) async => http.Response('', 500));
      await expectLater(
        downloadFile(bad, Uri.parse('https://example.org/a'), target),
        throwsA(isA<http.ClientException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });
}
