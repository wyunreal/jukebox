/* jukebox-ui-nav - client for the jukebox UI command channel.

   Injected into the Volumio UI by jukebox-ui-nav. It listens to the local
   ui-nav server (SSE) and runs commands *inside the UI*, so the UI updates
   itself (routing, the favourite heart, toasts, ...).

   Messages:
     {"type":"nav","view":"toggle"|"home"|"queue"}   switch screen
     {"type":"ui","action":"favourite"}               toggle current favourite

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

  function get(name) {
    var inj = injector();
    if (!inj) return null;
    try { return inj.get(name); } catch (err) { return null; }
  }

  function navigate(view) {
    var st = get("$state");
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

  /* Local files: the native path works, so use it unchanged.
     Radios: Volumio's backend has a gap — its checkFavourites() only looks at
     the music favourites list, so for webradio it always reports
     favourite:false and the heart never lights, and its native add always
     appends (never toggles). We handle radios ourselves: decide add vs remove
     from the radio-favourites file (via our /favourite endpoint) and keep the
     heart in sync by hooking the same "urifavourites" event the UI uses. */
  function setHeart(v) {
    var player = get("playerService");
    if (!player) return;
    player.favourite = player.favourite || {};
    if (player.favourite.favourite === !!v) return;
    player.favourite.favourite = !!v;
    var rs = get("$rootScope");
    if (rs && rs.$applyAsync) {
      try { rs.$applyAsync(function () {}); } catch (err) {}
    }
  }

  function isFavourite(service, uri, cb) {
    var url = base + "/favourite?service=" + encodeURIComponent(service) +
              "&uri=" + encodeURIComponent(uri);
    var req = new XMLHttpRequest();
    req.onreadystatechange = function () {
      if (req.readyState !== 4) return;
      var fav = false;
      try { fav = !!JSON.parse(req.responseText).favourite; } catch (err) {}
      cb(fav);
    };
    try { req.open("GET", url, true); req.send(); } catch (err) {}
  }

  function toggleRadio(player, list, st) {
    isFavourite("webradio", st.uri, function (fav) {
      if (fav) {
        list.removeFromFavourites(st);
      } else {
        var item = {};
        for (var k in st) { if (Object.prototype.hasOwnProperty.call(st, k)) item[k] = st[k]; }
        item.title = st.artist || st.title;  // the station name, not the song
        list.addToFavourites(item);
      }
      setHeart(!fav);
    });
  }

  function toggleFavourite() {
    var player = get("playerService");
    var list = get("playlistService");
    if (!player || !list || !player.state || !player.state.uri) return;
    if (player.state.service === "webradio") {
      toggleRadio(player, list, player.state);
      return;
    }
    // Native path (works for music).
    if (player.favourite && player.favourite.favourite) {
      list.removeFromFavourites(player.state);
    } else {
      list.addToFavourites(player.state);
    }
  }

  // Correct the heart for radios: the backend's "urifavourites" is always false
  // for webradio, so re-assert the real value from the file.
  function hookRadioHeart() {
    var sock = get("socketService");
    if (!sock || !sock.on) return false;
    sock.on("urifavourites", function (data) {
      if (!data || data.service !== "webradio" || !data.uri) return;
      isFavourite("webradio", data.uri, function (fav) { setHeart(fav); });
    });
    return true;
  }

  function handle(m) {
    if (!m) return;
    if (m.type === "nav") {
      navigate(m.view);
    } else if (m.type === "ui" && m.action === "favourite") {
      toggleFavourite();
    }
  }

  // Connect first, so a problem in the optional hooks never blocks the channel.
  try {
    var es = new EventSource(base + "/events");
    es.onmessage = function (e) {
      try { handle(JSON.parse(e.data)); } catch (err) {}
    };
  } catch (err) {}

  try {
    if (!hookRadioHeart()) {
      window.addEventListener("load", function () { hookRadioHeart(); });
    }
  } catch (err) {}
})();
