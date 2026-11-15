import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Repo der App und der Integration (öffentlich, GitHub-API ohne Token).
const String kAppRepo = 'phiph-s/haven';
const String kIntegrationRepo = 'phiph-s/haven-ha';

/// Mindestabstand zwischen zwei automatischen Prüfungen.
const Duration kUpdateCheckInterval = Duration(hours: 6);

Uri latestReleaseUri(String repo) =>
    Uri.https('api.github.com', '/repos/$repo/releases/latest');

/// Semantische Version `major.minor.patch` mit optionalem `-pre`. Build-Zusatz
/// (`+3`) und ein führendes `v` zählen nicht.
@immutable
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, [this.pre]);

  final int major;
  final int minor;
  final int patch;

  /// Pre-Release-Kennung (`beta.1`), `null` bei einer fertigen Version.
  final String? pre;

  static final _re = RegExp(
    r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$',
  );

  /// `null`, wenn der Text keine Version ist.
  static SemVer? tryParse(String? s) {
    final m = _re.firstMatch((s ?? '').trim());
    if (m == null) return null;
    return SemVer(
      int.parse(m[1]!),
      int.parse(m[2] ?? '0'),
      int.parse(m[3] ?? '0'),
      m[4],
    );
  }

  bool get isPre => pre != null;

  @override
  int compareTo(SemVer o) {
    final c = [
      major.compareTo(o.major),
      minor.compareTo(o.minor),
      patch.compareTo(o.patch),
    ].firstWhere((x) => x != 0, orElse: () => 0);
    if (c != 0) return c;
    if (pre == o.pre) return 0;
    // Eine fertige Version ist neuer als jede Vorabversion.
    if (pre == null) return 1;
    if (o.pre == null) return -1;
    return _comparePre(pre!, o.pre!);
  }

  static int _comparePre(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final na = int.tryParse(pa[i]);
      final nb = int.tryParse(pb[i]);
      final c = (na != null && nb != null)
          ? na.compareTo(nb)
          : (na != null ? -1 : (nb != null ? 1 : pa[i].compareTo(pb[i])));
      if (c != 0) return c;
    }
    return pa.length.compareTo(pb.length);
  }

  @override
  bool operator ==(Object other) => other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre);

  @override
  String toString() => '$major.$minor.$patch${pre == null ? '' : '-$pre'}';
}

/// `true`, wenn [candidate] neuer als [current] ist. Unlesbare Versionen
/// gelten nie als neuer.
bool isNewerVersion(String candidate, String current) {
  final a = SemVer.tryParse(candidate);
  final b = SemVer.tryParse(current);
  if (a == null || b == null) return false;
  return a.compareTo(b) > 0;
}

/// Ein veröffentlichtes Release mit dem passenden APK-Asset.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.apkSize,
    this.name,
  });

  /// Ohne `v`, z. B. `0.3.0`.
  final String version;
  final String tag;
  final String notes;

  /// Release-Seite auf GitHub.
  final String pageUrl;
  final String? apkUrl;
  final int? apkSize;
  final String? name;

  bool get hasApk => apkUrl != null;

  Map<String, dynamic> toJson() => {
    'version': version,
    'tag': tag,
    'notes': notes,
    'page_url': pageUrl,
    'apk_url': apkUrl,
    'apk_size': apkSize,
    'name': name,
  };

  static ReleaseInfo? fromStored(Object? j) {
    if (j is! Map) return null;
    final v = j['version'];
    final tag = j['tag'];
    final page = j['page_url'];
    if (v is! String || tag is! String || page is! String) return null;
    return ReleaseInfo(
      version: v,
      tag: tag,
      notes: (j['notes'] as String?) ?? '',
      pageUrl: page,
      apkUrl: j['apk_url'] as String?,
      apkSize: (j['apk_size'] as num?)?.toInt(),
      name: j['name'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReleaseInfo &&
      other.version == version &&
      other.apkUrl == apkUrl &&
      other.notes == notes;

  @override
  int get hashCode => Object.hash(version, apkUrl, notes);
}

/// Liest die Antwort von `releases/latest`. `null` bei Entwurf, Pre-Release,
/// unlesbarem Tag oder fehlenden Feldern. Das Asset heißt
/// `haven-<version>.apk` ([assetPrefix] `haven`), sonst gilt die einzige
/// andere APK-Datei, sonst gibt es kein APK (nur Link).
ReleaseInfo? parseRelease(Object? json, {String assetPrefix = 'haven'}) {
  if (json is! Map) return null;
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final v = SemVer.tryParse(tag);
  if (v == null || v.isPre) return null;
  final version = v.toString();
  final page = json['html_url'];
  final assets = [
    for (final a in (json['assets'] as List?) ?? const [])
      if (a is Map &&
          a['name'] is String &&
          a['browser_download_url'] is String)
        a,
  ];
  Map? apk;
  for (final a in assets) {
    if (a['name'] == '$assetPrefix-$version.apk') apk = a;
  }
  if (apk == null) {
    final others = [
      for (final a in assets)
        if ((a['name'] as String).toLowerCase().endsWith('.apk')) a,
    ];
    if (others.length == 1) apk = others.first;
  }
  final apkUrl = apk?['browser_download_url'] as String?;
  return ReleaseInfo(
    version: version,
    tag: tag,
    notes: ((json['body'] as String?) ?? '').trim(),
    pageUrl: page is String
        ? page
        : 'https://github.com/$kAppRepo/releases/tag/$tag',
    // Nur https, alles andere ignorieren wir.
    apkUrl: (apkUrl != null && apkUrl.startsWith('https://')) ? apkUrl : null,
    apkSize: (apk?['size'] as num?)?.toInt(),
    name: json['name'] as String?,
  );
}

/// `true`, wenn eine automatische Prüfung fällig ist.
bool isCheckDue(
  DateTime? lastCheck,
  DateTime now, {
  Duration interval = kUpdateCheckInterval,
}) {
  if (lastCheck == null) return true;
  final age = now.difference(lastCheck);
  // Uhr zurückgestellt: lieber prüfen.
  return age.isNegative || age >= interval;
}

/// Holt das neueste Release eines Repos. Der HTTP-Client ist austauschbar
/// (Tests, Entwicklungsdaten).
class ReleaseChecker {
  ReleaseChecker(this._client);
  final http.Client _client;

  /// `null`, wenn es kein passendes Release gibt (404, Entwurf, Pre-Release).
  /// Wirft bei Netzfehlern und anderen Statuscodes.
  Future<ReleaseInfo?> latest(
    String repo, {
    String assetPrefix = 'haven',
  }) async {
    final res = await _client
        .get(
          latestReleaseUri(repo),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GitHub antwortet mit ${res.statusCode}');
    }
    return parseRelease(
      jsonDecode(utf8.decode(res.bodyBytes)),
      assetPrefix: assetPrefix,
    );
  }
}
