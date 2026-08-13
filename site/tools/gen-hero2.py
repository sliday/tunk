#!/usr/bin/env python3
"""Hero v2. v1 put the fingers on the trackpad, which contradicts the product:
Tunk suppresses detection while the trackpad is being touched. The tap has to
land on bare chassis."""
import base64, json, os, sys, urllib.request

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated")

PROMPTS = {
    "hero2": (
        "Photograph, close three-quarter view of an open modern space-grey aluminium laptop on a "
        "warm oak desk in soft daylight from a window on the left. A person's right hand rests to "
        "the right of the laptop with index and middle fingertips touching the bare machined "
        "aluminium of the palm rest, in the empty metal area to the RIGHT of the trackpad, well "
        "clear of the trackpad and well clear of every key. Wide bare metal between the fingertips "
        "and the trackpad edge. The trackpad is fully visible, empty and untouched. Shallow depth "
        "of field, fingertips and palm rest sharp, screen dark and off, background falling away "
        "soft. No logos, no text, no screen content, no graphics, no overlay. Editorial product "
        "photography, natural light, calm neutral colour."
    ),
    "surface": (
        "Photograph, low three-quarter view of a closed space-grey aluminium laptop lying on a "
        "linen bedspread in soft evening light, seen from just above the surface so the folds of "
        "fabric run out of focus into the background. Emphasis on the machined edge of the lid "
        "against the soft textile. Muted neutral colour, quiet, editorial. No logos, no text, "
        "no graphics, nothing on screen."
    ),
}

SIZES = {"hero2": "1536x1024", "surface": "1536x1024"}


def gen(name):
    body = json.dumps({"model": "gpt-image-2", "prompt": PROMPTS[name],
                       "size": SIZES[name], "quality": "high", "n": 1}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations", data=body,
        headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"],
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    p = os.path.join(OUT, name + ".png")
    open(p, "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
    print("wrote", p, flush=True)


for n in sys.argv[1:] or list(PROMPTS):
    try:
        gen(n)
    except Exception as e:
        print("FAILED", n, e, getattr(e, "read", lambda: b"")().decode()[:400], flush=True)
