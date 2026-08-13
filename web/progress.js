// Optional. The page is complete without it: index.html is pre-rendered from
// progress.json by web/render.py, including how old the numbers were when the
// page was built. This script only sharpens that — it turns the baked stamps
// into live ones, escalates the staleness state against the real clock, and
// polls for a newer file.
(function () {
  "use strict";

  var POLL_MS = 20000;
  var TICK_MS = 15000;
  var root = document.documentElement;
  root.setAttribute("data-js", "on");

  // ---------------------------------------------------------------- age

  function fmtAge(secs) {
    secs = Math.max(0, Math.round(secs));
    if (secs < 60) return secs + " s";
    if (secs < 3600) return Math.floor(secs / 60) + " min";
    if (secs < 86400) {
      var h = Math.floor(secs / 3600);
      var m = Math.floor((secs % 3600) / 60);
      return h + " h " + (m < 10 ? "0" : "") + m + " min";
    }
    var d = Math.floor(secs / 86400);
    var hh = Math.floor((secs % 86400) / 3600);
    return d + " d " + (hh < 10 ? "0" : "") + hh + " h";
  }

  function relative(iso) {
    var then = Date.parse(iso);
    if (isNaN(then)) return null;
    var secs = Math.round((Date.now() - then) / 1000);
    if (secs < 0) return null;
    return fmtAge(secs) + " ago";
  }

  function stampRelativeTimes() {
    var nodes = document.querySelectorAll("time[data-relative]");
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var iso = node.getAttribute("datetime");
      var rel = relative(iso);
      if (!rel) continue;
      if (!node.dataset.absolute) node.dataset.absolute = node.textContent;
      node.textContent = node.dataset.absolute + " · " + rel;
      node.title = iso;
    }
  }

  // ---------------------------------------------------------------- staleness

  var fresh = document.querySelector(".freshness");
  var headText = fresh && fresh.querySelector(".fresh-head-text");
  var glyph = fresh && fresh.querySelector(".fresh-glyph--now");
  var agedGlyph = fresh && fresh.querySelector(".fresh-glyph--aged");
  if (agedGlyph) agedGlyph.parentNode.removeChild(agedGlyph);
  var openStale = fresh && fresh.querySelector(".fresh-open--stale");
  var openCold = fresh && fresh.querySelector(".fresh-open--cold");
  var generatedAt = fresh ? fresh.getAttribute("data-generated-at") : "";
  var staleAfter = fresh ? parseInt(fresh.getAttribute("data-stale-after"), 10) : 900;
  var coldAfter = fresh ? parseInt(fresh.getAttribute("data-cold-after"), 10) : 7200;
  var generatedMs = Date.parse(generatedAt);

  function setLevel(level) {
    if (!fresh) return;
    fresh.classList.remove("freshness--fresh", "freshness--stale",
                           "freshness--cold", "freshness--unknown");
    fresh.classList.add("freshness--" + level);
    root.setAttribute("data-freshness", level);
  }

  function updateAge() {
    if (!fresh) return;
    if (isNaN(generatedMs)) {
      setLevel("unknown");
      return;
    }
    var age = (Date.now() - generatedMs) / 1000;
    var level = age >= coldAfter ? "cold" : (age >= staleAfter ? "stale" : "fresh");
    setLevel(level);
    if (glyph) glyph.textContent = level === "fresh" ? "●" : "■";
    if (headText) {
      headText.textContent = level === "fresh"
        ? "Numbers written " + fmtAge(age) + " ago"
        : "STALE — these numbers are " + fmtAge(age) + " old";
    }
    if (openStale) {
      openStale.setAttribute("data-shown", level === "stale" ? "true" : "false");
      openStale.textContent = "progress.json has not been written for " + fmtAge(age)
        + ". A round in flight should be writing more often than this.";
    }
    if (openCold) {
      openCold.setAttribute("data-shown", level === "cold" ? "true" : "false");
      openCold.textContent = "progress.json has not been written for " + fmtAge(age)
        + ". Nothing here reflects a run that is still going.";
    }
  }

  // ---------------------------------------------------------------- polling

  var note = document.createElement("p");
  note.className = "refresh-note";
  note.setAttribute("role", "status");
  note.setAttribute("data-visible", "false");
  note.textContent = "";
  document.body.appendChild(note);

  function say(text) {
    note.textContent = text;
    note.setAttribute("data-visible", "true");
  }

  var baseline = null;
  var failures = 0;
  var pollable = location.protocol === "http:" || location.protocol === "https:";

  function poll() {
    if (!pollable) return;   // file:// cannot fetch; the static page still stands
    fetch("progress.json", { cache: "no-store" })
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (data) {
        failures = 0;
        var rounds = data.rounds || [];
        var signature = String(data.generated_at) + "#" + rounds.length;
        if (data.generated_at) {
          var parsed = Date.parse(data.generated_at);
          if (!isNaN(parsed)) {
            generatedMs = parsed;   // the file moved on even if the page has not
            updateAge();
          }
        }
        if (baseline === null) {
          baseline = signature;
          return;
        }
        if (signature !== baseline) {
          say("New round data — reloading");
          setTimeout(function () { location.reload(); }, 900);
        }
      })
      .catch(function () {
        failures += 1;
        if (failures >= 3) {
          say("Cannot read progress.json — this page may be out of date");
        }
      });
  }

  stampRelativeTimes();
  updateAge();
  setInterval(function () { stampRelativeTimes(); updateAge(); }, TICK_MS);
  poll();
  setInterval(poll, POLL_MS);
})();
