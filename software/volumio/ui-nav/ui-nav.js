/* jukebox-ui-nav - client for the jukebox navigation channel.

   Injected into the Volumio UI by jukebox-ui-nav. It listens to the local
   ui-nav server (SSE) and, on a navigation command, uses the UI's ui-router
   `$state` service to switch screens:

     {"type":"nav","view":"toggle"}  home <-> play queue
     {"type":"nav","view":"home"}    now-playing screen
     {"type":"nav","view":"queue"}   play queue

   It does nothing unless the page is the real Angular UI (so it is harmless in
   any other page that happens to load it). */
(function () {
  "use strict";
  if (window.__jkUiNavLoaded) return;
  window.__jkUiNavLoaded = true;

  var base = "http://" + (location.hostname || "localhost") + ":3211";

  function injector() {
    try {
      if (window.angular && window.angular.element) {
        return window.angular.element(document.body).injector();
      }
    } catch (err) {}
    return null;
  }

  function navigate(view) {
    var inj = injector();
    if (!inj) return;
    var st;
    try { st = inj.get("$state"); } catch (err) { return; }
    if (!st) return;
    if (view === "home") {
      st.go("volumio.playback");
    } else if (view === "queue") {
      st.go("volumio.play-queue");
    } else if (view === "toggle") {
      var now = st.current && st.current.name;
      st.go(now === "volumio.playback" ? "volumio.play-queue" : "volumio.playback");
    }
  }

  function handle(m) {
    if (m && m.type === "nav") navigate(m.view);
  }

  try {
    var es = new EventSource(base + "/events");
    es.onmessage = function (e) {
      try { handle(JSON.parse(e.data)); } catch (err) {}
    };
  } catch (err) {}
})();
