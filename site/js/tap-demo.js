/* ============================================================================
   The interactive tap demo, shared by the landing page and the demo page.

   Three things happen here:
     1. Canvas UI's Ripple runs over the photograph. Where Chrome exposes the
        html-in-canvas API (behind chrome://flags/#canvas-draw-element, or an
        origin trial token on the domain) the live DOM is drawn into a source
        canvas and the waves refract the page itself. Everywhere else the same
        wave field renders as light on the metal. One path, no error.
     2. Two knocks inside the window the detector joins wake the laptop screen.
        One knock ripples and does nothing, which is what the app does too.
     3. The playground controls tune the effect while it runs, and stay hidden
        unless the effect actually started.

   Every element is looked up by id and every step is optional, so a page that
   carries only some of them still works.
   ============================================================================ */

import { createRipple, supportsHtmlInCanvas } from "../vendor/canvasui-ripple.js";

const JOIN_WINDOW_MS = 400;

export function initTapDemo() {
  const fig = document.getElementById("hero-fig");
  const output = document.getElementById("hero-ripple");
  const lit = document.getElementById("hero-lit");
  if (!fig || !output) return null;

  const calm = matchMedia("(prefers-reduced-motion: reduce)");
  const live = supportsHtmlInCanvas();

  let source = null;
  if (live) {
    source = document.createElement("canvas");
    source.setAttribute("layoutsubtree", "true");
    source.className = "demo-stage__source";
    fig.parentNode.insertBefore(source, fig);
    source.appendChild(fig);
  }

  const options = {
    trigger: "click", interval: 7, amplitude: 0.8, wavelength: 64, rings: 2,
    decay: 1.1, shine: 1.1,
    refraction: live ? 120 : 0,
    dispersion: live ? 0.4 : 0,
  };

  const ripple = createRipple({ source, content: fig, output }, options);

  let previous = 0;
  let screenOn = false;
  const setScreen = (on) => {
    screenOn = on;
    if (lit) lit.classList.toggle("is-on", on);
  };

  fig.addEventListener("pointerdown", (event) => {
    if (previous && event.timeStamp - previous < JOIN_WINDOW_MS) {
      setScreen(!screenOn);
      previous = 0;                     // a third knock starts a new pair
    } else {
      previous = event.timeStamp;
    }
  }, { passive: true });

  const controls = document.getElementById("ripple-controls");
  if (ripple && controls) {
    controls.hidden = false;
    const note = document.getElementById("c-note");
    if (note) {
      note.textContent = live
        ? "Running over the live page: the waves bend the photograph itself."
        : "Drawing light only. Chrome with chrome://flags/#canvas-draw-element refracts the page instead.";
    }
    const bind = (id, key, cast) => {
      const input = document.getElementById(id);
      if (!input) return;
      input.addEventListener("input", () => {
        options[key] = cast(input.value);
        ripple.setOptions(options);
        ripple.splash(output.clientWidth * 0.5, output.clientHeight * 0.5, 0.7);
      });
    };
    bind("c-amp", "amplitude", Number);
    bind("c-speed", "speed", Number);
    bind("c-rings", "rings", (v) => Math.round(Number(v)));
  }

  // Show the gesture once on arrival: two beats 190 ms apart, the interval the
  // detector actually joins, then hand it back.
  if (ripple && !calm.matches) {
    const w = () => output.clientWidth;
    const h = () => output.clientHeight;
    setTimeout(() => ripple.splash(w() * 0.62, h() * 0.66, 1), 1200);
    setTimeout(() => { ripple.splash(w() * 0.72, h() * 0.63, 0.8); setScreen(true); }, 1390);
    setTimeout(() => setScreen(false), 3600);
  }

  return ripple;
}
