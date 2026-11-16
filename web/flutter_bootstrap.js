{{flutter_js}}
{{flutter_build_config}}

// Haven: Im Seitenleisten-Eintrag von Home Assistant startet `haven-panel.js`
// die App im eigenen Element (siehe dort). Sonst wie üblich in die Seite.
(function () {
  var panel = window.__havenPanel;
  if (panel && typeof panel.boot === "function") {
    panel.boot(window._flutter);
    return;
  }
  _flutter.loader.load({
    // Der Panel-Build enthält nur die volle CanvasKit.
    config: { canvasKitVariant: "full" },
    serviceWorkerSettings: {
      serviceWorkerVersion: {{flutter_service_worker_version}},
    },
  });
})();
