// Optional. The page is complete without it: index.html is pre-rendered from
// progress.json by web/render.py. This only polls for a newer file and turns the
// absolute timestamps into relative ones.
(function () {
  "use strict";

  var POLL_MS = 20000;

  function relative(iso) {
    var then = Date.parse(iso);
    if (isNaN(then)) return null;
    var secs = Math.round((Date.now() - then) / 1000);
    if (secs < 0) return null;
    if (secs < 60) return secs + "s ago";
    if (secs < 3600) return Math.round(secs / 60) + "m ago";
    if (secs < 86400) return Math.round(secs / 3600) + "h ago";
    return Math.round(secs / 86400) + "d ago";
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

  var note = document.createElement("p");
  note.className = "refresh-note";
  note.setAttribute("role", "status");
  note.setAttribute("data-visible", "false");
  note.textContent = "";
  document.body.appendChild(note);

  var baseline = null;

  function poll() {
    fetch("progress.json", { cache: "no-store" })
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (data) {
        if (!data) return;
        var rounds = data.rounds || [];
        var signature = String(data.generated_at) + "#" + rounds.length;
        if (baseline === null) {
          baseline = signature;
          return;
        }
        if (signature !== baseline) {
          note.textContent = "New round data — reloading";
          note.setAttribute("data-visible", "true");
          setTimeout(function () { location.reload(); }, 900);
        }
      })
      .catch(function () { /* file:// or offline; the static page still stands */ });
  }

  stampRelativeTimes();
  setInterval(stampRelativeTimes, 30000);
  poll();
  setInterval(poll, POLL_MS);
})();
