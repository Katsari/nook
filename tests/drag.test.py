#!/usr/bin/env python3
"""Drag a widget into Nook and back out, using a real pointer.

Nothing else reaches this code path. The bar starts a drag from its own pointer
handlers and Nook reads the bar's drag state, so absorb-by-drag, the reveal, and
eject-by-drag can only be exercised by moving the pointer for real.

Usage: tests/drag.test.py [source-widget-id]   (default: omarchy.spacer)

Needs tests/tools/vptr/vptr (run its build.sh once), a running omarchy-shell,
and a Wayland session. Keep hands off the mouse while it runs. shell.json is
snapshotted at the start and restored at the end, pass or fail.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

NOOK = "io.github.katsari.nook"
SOURCE = sys.argv[1] if len(sys.argv) > 1 else "omarchy.spacer"
ROOT = pathlib.Path(__file__).resolve().parent.parent
VPTR = ROOT / "tests" / "tools" / "vptr" / "vptr"
CONFIG = pathlib.Path.home() / ".config" / "omarchy" / "shell.json"


def sh(*args):
    return subprocess.check_output(args, text=True)


def screen():
    monitor = next(m for m in json.loads(sh("hyprctl", "monitors", "-j")) if m["focused"])
    return round(monitor["width"] / monitor["scale"]), round(monitor["height"] / monitor["scale"])


def geometry():
    # debugBarGeometry can fail while a layout write rebuilds the bar. The
    # budget stays under wait_for's timeouts.
    deadline = time.time() + 3
    while True:
        try:
            slots = json.loads(sh("omarchy-shell", "shell", "debugBarGeometry"))
            return {s["id"]: s for s in slots}
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            if time.time() > deadline:
                raise
            time.sleep(0.3)


def center(slot):
    return slot["x"] + slot["width"] // 2, slot["y"] + slot["height"] // 2


def item_center(slot):
    """A hosted widget's own box. Its slot is a zero-size lookup shim, but the
    slot's origin is the cell's position on screen and itemWidth/itemHeight are
    the widget's real size."""
    return slot["x"] + slot["itemWidth"] // 2, slot["y"] + slot["itemHeight"] // 2


class Pointer:
    """One virtual pointer for the whole test. Destroying the device drops
    hover, which would shut the drawer between steps, so it stays open on stdin
    from the first move to the last."""

    def __init__(self):
        width, height = screen()
        self.proc = subprocess.Popen(
            [str(VPTR), str(width), str(height)], stdin=subprocess.PIPE, text=True
        )

    def send(self, *commands):
        for command in commands:
            self.proc.stdin.write(" ".join(map(str, command)) + "\n")
        self.proc.stdin.flush()
        # vptr sleeps in-process, so wait out its pauses before reading the shell.
        time.sleep(sum(c[1] for c in commands if c[0] == "s") / 1000 + 0.15)

    def move(self, point, dwell=250):
        self.send(("m", point[0], point[1]), ("s", dwell))

    def glide(self, start, end, steps=8):
        """Walk between two points. The reveal survives a continuous path but
        not a jump: one absolute motion from the bar into the strip leaves the
        chevron unhovered for longer than the drawer's grace period."""
        commands = []
        for i in range(1, steps + 1):
            commands += [
                ("m",
                 start[0] + (end[0] - start[0]) * i // steps,
                 start[1] + (end[1] - start[1]) * i // steps),
                ("s", 80),
            ]
        self.send(*commands)

    def drag(self, start, end, steps=16):
        """Press, move in steps past the drag threshold, release. The pauses are
        generous because every step has to survive a compositor round trip and
        the bar only starts a drag once it has seen the press and enough
        motion."""
        commands = [("m", start[0], start[1]), ("s", 250), ("d",), ("s", 250)]
        for i in range(1, steps + 1):
            commands += [
                ("m",
                 start[0] + (end[0] - start[0]) * i // steps,
                 start[1] + (end[1] - start[1]) * i // steps),
                ("s", 50),
            ]
        commands += [("s", 350), ("u",), ("s", 500)]
        self.send(*commands)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def config():
    return json.loads(CONFIG.read_text())


def nook_entry(cfg=None):
    cfg = cfg or config()
    for section in ("left", "center", "right"):
        for entry in cfg["bar"]["layout"].get(section, []):
            if isinstance(entry, dict) and entry.get("id") == NOOK:
                return entry
    raise AssertionError("Nook is not in the bar layout; this test needs it there")


def hosted_ids(cfg=None):
    return [
        e["id"] if isinstance(e, dict) else e
        for e in nook_entry(cfg).get("items", [])
    ]


def on_bar(widget_id, cfg=None):
    cfg = cfg or config()
    for section in ("left", "center", "right"):
        for entry in cfg["bar"]["layout"].get(section, []):
            if (entry.get("id") if isinstance(entry, dict) else entry) == widget_id:
                return True
    return False


def wait_for(check, what, timeout=6.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if check():
                return
        except Exception:
            pass
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def main():
    if not VPTR.exists():
        print(f"drag.test.py: {VPTR} not built, run tests/tools/vptr/build.sh", file=sys.stderr)
        return 1
    if not os.environ.get("WAYLAND_DISPLAY"):
        print("drag.test.py: no Wayland session, skipping", file=sys.stderr)
        return 0

    slots = geometry()
    if NOOK not in slots or not slots[NOOK]["visible"]:
        print("drag.test.py: Nook is not visible on the bar, skipping", file=sys.stderr)
        return 0
    if SOURCE not in slots or not slots[SOURCE]["visible"]:
        print(f"drag.test.py: {SOURCE} is not visible on the bar, skipping", file=sys.stderr)
        return 0
    if SOURCE in hosted_ids():
        print(f"drag.test.py: {SOURCE} is already inside Nook, skipping", file=sys.stderr)
        return 0

    backup = pathlib.Path(tempfile.mkdtemp()) / "shell.json"
    shutil.copy(CONFIG, backup)
    print(f"drag.test.py: shell.json backed up to {backup}")

    mouse = Pointer()
    try:
        chevron = center(slots[NOOK])
        source = center(slots[SOURCE])

        # 1. bar -> drawer
        mouse.drag(source, chevron)
        try:
            wait_for(lambda: SOURCE in hosted_ids(), "the absorb to be written", 2.0)
        except AssertionError:
            # A drag that never crossed the threshold leaves no trace, so this
            # is a retry, not a second assertion.
            fresh = geometry()
            mouse.drag(center(fresh[SOURCE]), center(fresh[NOOK]))
        wait_for(lambda: SOURCE in hosted_ids(), f"{SOURCE} to land in Nook's items")
        assert not on_bar(SOURCE), f"{SOURCE} is in items but still in the bar layout"
        print(f"ok: dragged {SOURCE} from the bar into Nook")

        # 2. hovering really opens the drawer and the widget really gets drawn.
        # itemVisible is false while the strip is shut: the cell's loader hides
        # its child so the bar does not route clicks into a closed drawer.
        # Absorbing shortens the section the widget came from, so every slot
        # after it shifts. Ask again rather than reusing the opening reading.
        chevron = center(geometry()[NOOK])
        # Away first: the drop left the pointer on the chevron, which holds the
        # drawer open, and hovering a spot it already occupies produces no new
        # enter event either.
        mouse.move((chevron[0], chevron[1] + 300), dwell=400)
        wait_for(lambda: not geometry()[SOURCE]["itemVisible"],
                 f"the drawer to shut and stop drawing {SOURCE}")
        mouse.move(chevron, dwell=900)
        wait_for(
            lambda: geometry()[SOURCE]["itemVisible"],
            f"{SOURCE} to be drawn inside the open drawer",
        )
        hosted = geometry()[SOURCE]
        assert hosted["y"] > slots[NOOK]["y"] + slots[NOOK]["height"] - 1, (
            f"{SOURCE} rendered at y={hosted['y']}, which is not below the bar"
        )
        print(f"ok: hover opened the drawer, {SOURCE} drawn at "
              f"{hosted['x']},{hosted['y']} {hosted['itemWidth']}x{hosted['itemHeight']}")

        # 3. reorder inside the drawer, drifting up onto the bar's edge on the
        # way. Only a deliberate move onto the bar means eject.
        before = hosted_ids()
        if len(before) < 2:
            print("drag.test.py: single hosted item, skipping the reorder step")
        else:
            neighbour = geometry()[before[0]] if before[0] != SOURCE else geometry()[before[1]]
            # The near edge, not the midpoint: a drop on an even-width cell's
            # midpoint resolves the caret to the dragged item's own slot.
            drift = (neighbour["x"] + 2, slots[NOOK]["y"] + slots[NOOK]["height"] - 2)
            mouse.glide(chevron, item_center(hosted))
            mouse.drag(item_center(hosted), drift)
            wait_for(lambda: hosted_ids() != before, f"{SOURCE} to move in the drawer")
            assert SOURCE in hosted_ids(), f"a drifting reorder ejected {SOURCE}"
            print(f"ok: reordered {SOURCE} without ejecting it, {before} -> {hosted_ids()}")

        # 4. drawer -> bar. The reorder left the pointer off the chevron and
        # the drawer may have shut, so reopen it first.
        bar_now = geometry()
        target = center(bar_now["omarchy.clock"]) if "omarchy.clock" in bar_now else (source[0], 12)
        chevron = center(bar_now[NOOK])
        mouse.move(chevron, dwell=900)
        wait_for(lambda: geometry()[SOURCE]["itemVisible"],
                 f"{SOURCE} to be drawn before the eject")
        hosted = geometry()[SOURCE]
        mouse.glide(chevron, item_center(hosted))
        mouse.drag(item_center(hosted), target)
        wait_for(lambda: SOURCE not in hosted_ids(), f"{SOURCE} to leave Nook's items")
        assert on_bar(SOURCE), f"{SOURCE} left items but is not in the bar layout"
        print(f"ok: dragged {SOURCE} back out onto the bar")

    finally:
        mouse.send(("u",), ("m", 10, 600))
        mouse.close()
        shutil.copy(backup, CONFIG)
        time.sleep(1.0)
        print("drag.test.py: shell.json restored")

    print("drag.test.py: all drags passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
