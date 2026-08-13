#!/usr/bin/env python3
"""Generate site imagery with OpenAI gpt-image-2. One prompt per asset."""
import base64
import json
import os
import sys
import urllib.request

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated")
os.makedirs(OUT, exist_ok=True)

PROMPTS = {
    "hero": (
        "Photograph, close three-quarter view of an open modern space-grey aluminium laptop "
        "on a warm oak desk in soft daylight from a window on the left. A person's right hand "
        "hovers just above the palm rest to the right of the trackpad, index and middle fingers "
        "extended, caught mid-tap against the metal body, fingertips barely touching. Shallow "
        "depth of field, the fingertips and the palm rest sharp, the screen and background "
        "falling out of focus. Screen is dark and off, no logos, no text, no visible brand marks "
        "anywhere. Calm neutral colour, gentle specular highlight along the machined edge of the "
        "case. Editorial product photography, natural light, no studio flash, no graphics, "
        "no user interface, no overlay."
    ),
    "gesture": (
        "Photograph, tight overhead macro of two fingertips resting on the brushed aluminium "
        "palm rest of a laptop, seen from directly above, the fingers entering from the right "
        "edge of the frame. Soft north light, fine machining grain visible in the metal, subtle "
        "warm shadow under the knuckles. Muted neutral palette, generous empty metal surface on "
        "the left half of the frame. No screen, no keyboard keys, no logos, no text, no graphics."
    ),
    "menubar": (
        "Photograph, close side view of the top right corner of a laptop screen bezel and the "
        "thin aluminium lid edge, shot at a shallow angle in soft daylight so the corner "
        "recedes into a clean blurred background. Nothing on the screen, screen is dark. "
        "Emphasis on the precision of the machined edge and the join between glass and metal. "
        "Neutral colour, quiet, editorial. No logos, no text, no user interface, no icons."
    ),
}

SIZES = {"hero": "1536x1024", "gesture": "1536x1024", "menubar": "1024x1024"}


def gen(name):
    body = json.dumps({
        "model": "gpt-image-2",
        "prompt": PROMPTS[name],
        "size": SIZES[name],
        "quality": "high",
        "n": 1,
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=body,
        headers={
            "Authorization": "Bearer " + os.environ["OPENAI_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    path = os.path.join(OUT, name + ".png")
    with open(path, "wb") as f:
        f.write(base64.b64decode(d["data"][0]["b64_json"]))
    print("wrote", path, flush=True)


for n in sys.argv[1:] or list(PROMPTS):
    try:
        gen(n)
    except Exception as e:
        detail = e.read().decode()[:500] if hasattr(e, "read") else ""
        print("FAILED", n, e, detail, flush=True)
