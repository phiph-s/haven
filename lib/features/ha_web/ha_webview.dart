import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/tokens.dart';
import 'ha_auth_bridge.dart';

/// WebView mit der `externalApp`-Auth-Brücke. Nur auf Android und iOS
/// verwenden, nicht im Web und nicht in Tests.
class HaWebView extends StatefulWidget {
  const HaWebView({
    super.key,
    required this.uri,
    required this.reload,
    required this.readToken,
  });

  final Uri uri;
  final Listenable reload;
  final Future<String?> Function() readToken;

  @override
  State<HaWebView> createState() => _HaWebViewState();
}

class _HaWebViewState extends State<HaWebView> {
  late final WebViewController _c;
  int _progress = 0;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(haExternalAuthChannel, onMessageReceived: _onMsg)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            setState(() => _error = false);
            _inject();
          },
          onProgress: (p) {
            if (p < 40) _inject();
            if (mounted) setState(() => _progress = p);
          },
          // Nur die eigene HA-Instanz, keine fremden Seiten im Vollbild.
          onNavigationRequest: (r) {
            final u = Uri.tryParse(r.url);
            return u != null && u.host == widget.uri.host
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? false) setState(() => _error = true);
          },
        ),
      )
      ..loadRequest(widget.uri);
    widget.reload.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reload.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    setState(() => _error = false);
    _c.loadRequest(widget.uri);
  }

  void _inject() => _c.runJavaScript(haExternalAuthScript);

  Future<void> _onMsg(JavaScriptMessage m) async {
    final msg = parseExternalAuthMessage(m.message);
    if (msg == null) return;
    switch (msg.kind) {
      case ExternalAuthKind.get:
        final token = await widget.readToken();
        final js = token == null
            ? authFailureJs(msg.callback)
            : authSuccessJs(msg.callback, token);
        if (js != null) await _c.runJavaScript(js);
      case ExternalAuthKind.revoke:
        // Der Token gehört der App, abgemeldet wird in den Einstellungen.
        final js = authAckJs(msg.callback);
        if (js != null) await _c.runJavaScript(js);
      case ExternalAuthKind.other:
        if (kDebugMode) debugPrint('externalApp: ${jsonEncode(m.message)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _c)),
        if (_progress < 100 && !_error)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              minHeight: 3,
              color: hv.acc,
              backgroundColor: hv.s2,
            ),
          ),
        if (_error)
          Positioned.fill(
            child: ColoredBox(
              color: hv.bg,
              child: Center(
                child: Text(
                  'Home Assistant ist nicht erreichbar.\nPrüfe die Adresse und dein Netz.',
                  textAlign: TextAlign.center,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
