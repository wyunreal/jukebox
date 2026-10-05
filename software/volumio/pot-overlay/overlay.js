/* jukebox pot overlay: shows a circular indicator when the balance, bass or
   treble pot moves.  Injected into the Volumio UI by jukebox-overlay.

   It deliberately reuses Volumio's own building blocks so it looks and behaves
   like the volume scrim: the .knobWrapper / .knobInfosWrapper markup and the
   jQuery-knob plugin the UI already ships.  Values arrive over Server-Sent
   Events from the jukebox-overlay server (fed by the jukebox-pots daemon). */
(function () {
  "use strict";
  if (window.__jkOverlayLoaded) return;
  window.__jkOverlayLoaded = true;

  var base = "http://" + (location.hostname || "localhost") + ":3210";
  var HIDE_MS = 3000; /* the same dwell as Volumio's volume scrim */

  var link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = base + "/overlay.css";
  document.head.appendChild(link);

  var el = document.createElement("div");
  el.id = "jkOverlay";
  el.innerHTML =
    '<div class="jk-scrim"></div>' +
    '<div class="knobWrapper">' +
      '<div class="knobInfosWrapper">' +
        '<div class="headerText green"><span class="jk-title"></span></div>' +
        '<div class="bigText">' +
          '<span class="jk-value"></span>' +
        "</div>" +
        '<div class="smallText jk-unit"></div>' +
      "</div>" +
      '<div class="jk-knob"></div>' +
    "</div>";

  function mount() {
    (document.body || document.documentElement).appendChild(el);
  }
  if (document.body) {
    mount();
  } else {
    document.addEventListener("DOMContentLoaded", mount);
  }

  var titleEl = el.querySelector(".jk-title");
  var valueEl = el.querySelector(".jk-value");
  var unitEl = el.querySelector(".jk-unit");
  var knobEl = el.querySelector(".jk-knob");
  var hideTimer = null;
  var knobReady = false;

  /* Wait for the UI's jQuery + jQuery-knob (both in the vendor bundle) and
     build a read-only knob with the same options as the volume scrim. */
  function initKnob() {
    if (knobReady) return;
    if (window.jQuery && window.jQuery.fn && window.jQuery.fn.knob) {
      try {
        window.jQuery(knobEl).knob({
          min: 0,
          max: 100,
          width: 210,
          height: 210,
          displayInput: false,
          step: 1,
          angleOffset: -160,
          angleArc: 320,
          readOnly: true,
          thickness: 0.2,
          fgColor: "#ffffff",
          bgColor: "#b6b6b633"
        });
        knobReady = true;
      } catch (err) {}
    }
    if (!knobReady) setTimeout(initKnob, 50);
  }
  initKnob();

  function setValue(v) {
    if (!knobReady) return;
    try {
      window.jQuery(knobEl).val(v).trigger("change");
    } catch (err) {}
  }

  function show(title, value, unit, position, color) {
    titleEl.textContent = title;
    valueEl.textContent = value;
    valueEl.classList.toggle("jk-long", value.length >= 4);
    unitEl.textContent = unit || "";
    setValue(position);
    el.classList.add("jk-show");
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(function () {
      el.classList.remove("jk-show");
    }, HIDE_MS);
  }

  function clamp(v, lo, hi) {
    v = Number(v) || 0;
    return v < lo ? lo : v > hi ? hi : v;
  }

  function round2(v) {
    return Math.round(v * 100) / 100;
  }

  function render(m) {
    if (!m || !m.type) return;
    if (m.type === "balance") {
      var pan = clamp(m.pan, -1, 1);
      if (Math.abs(pan) < 0.02) pan = 0;
      var mag = Math.round(Math.abs(pan) * 100);
      var label = pan === 0 ? "C" : (pan < 0 ? "L " + mag : "R " + mag);
      show("Balance", label, "", Math.round(((pan + 1) / 2) * 100));
    } else if (m.type === "bass" || m.type === "treble") {
      var max = Math.abs(Number(m.max)) || 8;
      var db = round2(clamp(m.db, -max, max));
      var name = m.type === "bass" ? "Bass" : "Treble";
      show(name, (db > 0 ? "+" : "") + db.toFixed(1), "dB",
           Math.round(((db + max) / (2 * max)) * 100));
    }
  }

  try {
    var es = new EventSource(base + "/events");
    es.onmessage = function (e) {
      try { render(JSON.parse(e.data)); } catch (err) {}
    };
  } catch (err) {}
})();
