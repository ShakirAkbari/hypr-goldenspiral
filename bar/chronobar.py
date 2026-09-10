#!/usr/bin/env python3
"""
chronobar: the goldenspiral app bar.

A time-ordered dock rendered as a normal GTK4 window (app id
"org.goldenspiral.chronobar"). It is not a layer-shell surface: the
goldenspiral layout recognises this window by its class and pins it to a fixed
slot in the bottom-right corner, laying the other windows out around it.

Two zones, split by a divider:

  left  - recently CLOSED apps, newest leftmost. An app lands here when its last
          window closes and leaves the moment it is reopened.
  right - apps with a live window now, newest nearest the corner, with a count
          badge when an app has more than one window.

One chip per application. Left-click launches a new instance. Right-click a
right-zone chip for a menu of that app's windows; pick one to pull it onto the
current workspace and promote it to the goldenspiral mainstage.

Config (hot-reloaded): ~/.config/goldenspiral/bar.json

MIT License, Copyright (c) 2026 Shakir Akbari.
"""

import json
import os
import socket
import threading
import warnings

import gi

from gi import PyGIDeprecationWarning

warnings.filterwarnings("ignore", category=PyGIDeprecationWarning)

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

APP_ID = "org.goldenspiral.chronobar"
CONFIG_PATH = os.path.expanduser("~/.config/goldenspiral/bar.json")

DEFAULTS = {
    "iconSize": 64,
    "gap": 8,
    "maxOpen": 0,
    "maxClosed": 8,
    "showNames": True,
    "showCounts": True,
    "zoneLabels": True,
    "promoteOnPick": True,
}


# --------------------------------------------------------------------------- IPC
class Hypr:
    """Thin Hyprland IPC client: request socket for queries and dispatch,
    event socket for a line stream."""

    def __init__(self):
        sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        run = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        self.req_path = f"{run}/hypr/{sig}/.socket.sock"
        self.evt_path = f"{run}/hypr/{sig}/.socket2.sock"
        self.lua = self._detect_lua()

    def _detect_lua(self):
        try:
            return b"configProvider: lua" in self.request("systeminfo").encode()
        except Exception:
            return False

    def request(self, cmd):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(self.req_path)
            s.sendall(cmd.encode())
            out = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                out += chunk
        return out.decode("utf-8", "replace")

    def json(self, cmd):
        try:
            return json.loads(self.request("j/" + cmd))
        except Exception:
            return None

    def dispatch(self, payload):
        try:
            self.request("dispatch " + payload)
        except Exception:
            pass

    def focus_workspace_id(self):
        ws = self.json("activeworkspace")
        return ws.get("id") if isinstance(ws, dict) else None

    def bring_to_mainstage(self, address, promote):
        ws = self.focus_workspace_id()
        if ws is None:
            return
        if self.lua:
            self.dispatch(
                'hl.dsp.window.move({ window = "address:%s", workspace = "%s", '
                "follow = true })" % (address, ws)
            )
        else:
            self.dispatch("movetoworkspace %s,address:%s" % (ws, address))
        if promote:
            GLib.timeout_add(
                120,
                lambda: (
                    self.dispatch(
                        'hl.dsp.layout("promote")' if self.lua else "layoutmsg promote"
                    ),
                    False,
                )[1],
            )

    def watch_events(self, on_line):
        def run():
            while True:
                try:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.connect(self.evt_path)
                    buf = b""
                    while True:
                        chunk = s.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            GLib.idle_add(on_line, line.decode("utf-8", "replace"))
                except Exception:
                    pass
                GLib.usleep(500_000)  # reconnect after a drop

        threading.Thread(target=run, daemon=True).start()


# ------------------------------------------------------------------ desktop info
class Apps:
    """class name -> Gio.DesktopAppInfo, resolved heuristically and cached."""

    def __init__(self):
        self._cache = {}
        self._by_wmclass = {}
        self._index()

    def _index(self):
        self._by_wmclass.clear()
        for info in Gio.AppInfo.get_all():
            if not isinstance(info, Gio.DesktopAppInfo):
                continue
            wm = info.get_string("StartupWMClass")
            if wm:
                self._by_wmclass[wm.lower()] = info

    def lookup(self, cls):
        if not cls:
            return None
        key = cls.lower()
        if key in self._cache:
            return self._cache[key]
        info = self._by_wmclass.get(key)
        if info is None:
            for cand in (cls, key, key.split(".")[-1], key.split("-")[0]):
                try:
                    info = Gio.DesktopAppInfo.new(cand + ".desktop")
                except (TypeError, GLib.Error):
                    info = None
                if info:
                    break
        if info is None:
            self._index()  # a new app may have been installed
            info = self._by_wmclass.get(key)
        self._cache[key] = info
        return info

    def icon(self, cls):
        info = self.lookup(cls)
        return info.get_icon() if info else None

    def name(self, cls):
        info = self.lookup(cls)
        return info.get_name() if info else cls

    def launch(self, cls):
        info = self.lookup(cls)
        if info:
            info.launch([], None)


# ------------------------------------------------------------------------- state
class Model:
    def __init__(self):
        self.recency = []       # app classes, most-recently focused first
        self.closed = []        # recently-closed classes, newest first
        self.open = []          # classes with a live window, recency order
        self.windows = {}       # class -> [{address, title}, ...]
        self._prev_open = None

    def bump(self, cls):
        if not cls:
            return
        self.recency = [cls] + [c for c in self.recency if c != cls]

    def recompute(self, clients, has_entry):
        live = {}
        wins = {}
        for c in clients or []:
            cls = (c.get("class") or "").lower()
            if not cls or cls == APP_ID.lower():
                continue  # never list the bar itself
            live[cls] = True
            wins.setdefault(cls, []).append(
                {"address": c.get("address"), "title": c.get("title") or cls}
            )
        self.windows = wins

        if self._prev_open is not None:
            for cls in self._prev_open:
                if cls not in live and cls not in self.closed and has_entry(cls):
                    self.closed.insert(0, cls)
        for cls in list(self.closed):
            if cls in live:
                self.closed.remove(cls)
        self._prev_open = set(live)

        self.open = [c for c in self.recency if c in live]
        for cls in live:
            if cls not in self.open:
                self.open.append(cls)


# --------------------------------------------------------------------------- app
class Chronobar(Gtk.Application):
    def __init__(self):
        # NON_UNIQUE: goldenspiral launches exactly one, and a stray second
        # launch should be its own process, not a second window in the first.
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.cfg = dict(DEFAULTS)
        self.win = None
        self.hypr = Hypr()
        self.apps = Apps()
        self.model = Model()
        self._refresh_queued = False

    # -- lifecycle --
    def do_activate(self):
        if self.win is not None:
            self.win.present()
            return
        self.win = Gtk.ApplicationWindow(application=self)
        self.win.set_decorated(False)
        self.win.set_title("chronobar")
        self.win.add_css_class("chronobar")
        self.win.set_default_size(900, 150)

        self.root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.root.add_css_class("bar")
        self.win.set_child(self.root)

        self._load_css()
        self._load_config()
        self._watch_config()

        self.hypr.watch_events(self._on_event)
        self._queue_refresh()
        self.win.present()

    # -- config --
    def _load_config(self):
        cfg = dict(DEFAULTS)
        try:
            with open(CONFIG_PATH) as f:
                user = json.load(f)
            for k in DEFAULTS:
                if k in user:
                    cfg[k] = user[k]
        except FileNotFoundError:
            pass
        except Exception as e:
            print("chronobar: bad bar.json:", e)
        self.cfg = cfg
        self._rebuild()

    def _watch_config(self):
        try:
            os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
            gf = Gio.File.new_for_path(CONFIG_PATH)
            self._mon = gf.monitor_file(Gio.FileMonitorFlags.NONE, None)
            self._mon.connect("changed", lambda *_: self._load_config())
        except Exception:
            pass

    def _load_css(self):
        css = b"""
        .chronobar, .bar { background: transparent; }
        .bar { padding: 8px 12px; }
        .glass {
            background: rgba(38, 42, 58, 0.34);
            border: 1px solid rgba(255, 255, 255, 0.16);
            border-radius: 18px;
        }
        .zonelabel {
            font-size: 10px;
            color: rgba(255, 255, 255, 0.42);
            margin: 0 6px;
        }
        .chip { border-radius: 12px; padding: 4px 6px; }
        .chip:hover { background: rgba(255, 255, 255, 0.12); }
        .chipname { font-size: 11px; color: #dfe4f2; }
        .divider { background: rgba(255, 255, 255, 0.16); min-width: 1px; margin: 6px 10px; }
        .badge {
            background: rgba(61, 125, 242, 0.96);
            color: white; font-size: 10px; font-weight: bold;
            border-radius: 9px; padding: 0 5px; margin: 2px;
        }
        popover contents { padding: 4px; }
        .winrow { padding: 6px 10px; border-radius: 6px; }
        .winrow:hover { background: rgba(255, 255, 255, 0.12); }
        """
        prov = Gtk.CssProvider()
        prov.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            self.win.get_display(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    # -- events --
    def _on_event(self, line):
        name, _, data = line.partition(">>")
        if name == "activewindowv2":
            addr = "0x" + data.strip() if not data.startswith("0x") else data.strip()
            for cls, wins in self.model.windows.items():
                if any(w["address"] == addr for w in wins):
                    self.model.bump(cls)
                    break
        if name in ("activewindowv2", "openwindow", "closewindow", "movewindowv2"):
            self._queue_refresh()
        return False

    def _queue_refresh(self):
        if self._refresh_queued:
            return
        self._refresh_queued = True
        GLib.timeout_add(40, self._do_refresh)

    def _do_refresh(self):
        self._refresh_queued = False
        clients = self.hypr.json("clients") or []
        self.model.recompute(clients, lambda c: self.apps.lookup(c) is not None)
        self._rebuild()
        return False

    # -- rendering --
    def _rebuild(self):
        if not hasattr(self, "root"):
            return
        while (child := self.root.get_first_child()) is not None:
            self.root.remove(child)

        closed = self.model.closed
        opened = self.model.open
        if self.cfg["maxClosed"] > 0:
            closed = closed[: self.cfg["maxClosed"]]
        if self.cfg["maxOpen"] > 0:
            opened = opened[: self.cfg["maxOpen"]]

        glass = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        glass.add_css_class("glass")
        glass.set_hexpand(True)
        glass.set_vexpand(True)

        left = self._zone("recently closed", closed, Gtk.Align.START, counts=False)
        left.set_hexpand(True)  # takes the slack, keeping the two groups apart
        glass.append(left)

        div = Gtk.Box()
        div.add_css_class("divider")
        div.set_visible(bool(closed) and bool(opened))
        glass.append(div)

        glass.append(self._zone("open", opened, Gtk.Align.END, counts=True))
        self.root.append(glass)

    def _zone(self, label, classes, halign, counts):
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        col.set_halign(halign)
        col.set_valign(Gtk.Align.CENTER)
        if self.cfg["zoneLabels"]:
            lb = Gtk.Label(label=label, xalign=0 if halign == Gtk.Align.START else 1)
            lb.add_css_class("zonelabel")
            lb.set_halign(halign)
            col.append(lb)
        strip = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=self.cfg["gap"])
        strip.set_halign(halign)
        for cls in classes:
            strip.append(self._chip(cls, counts))
        col.append(strip)
        return col

    def _chip(self, cls, counts):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.add_css_class("chip")

        gicon = self.apps.icon(cls)
        img = (
            Gtk.Image.new_from_gicon(gicon)
            if gicon
            else Gtk.Image.new_from_icon_name("application-x-executable")
        )
        img.set_pixel_size(self.cfg["iconSize"])

        nwin = len(self.model.windows.get(cls, [])) if counts else 0
        if counts and nwin > 1 and self.cfg["showCounts"]:
            ov = Gtk.Overlay()
            ov.set_child(img)
            badge = Gtk.Label(label=str(nwin))
            badge.add_css_class("badge")
            badge.set_halign(Gtk.Align.END)
            badge.set_valign(Gtk.Align.START)
            ov.add_overlay(badge)
            box.append(ov)
        else:
            box.append(img)

        if self.cfg["showNames"]:
            name = Gtk.Label(label=self.apps.name(cls))
            name.add_css_class("chipname")
            name.set_ellipsize(3)  # PANGO_ELLIPSIZE_END
            name.set_max_width_chars(12)
            box.append(name)

        left = Gtk.GestureClick()
        left.set_button(1)
        left.connect("released", lambda *_: self.apps.launch(cls))
        box.add_controller(left)

        if counts:
            right = Gtk.GestureClick()
            right.set_button(3)
            right.connect("released", lambda g, *_: self._window_menu(cls, g.get_widget()))
            box.add_controller(right)

        box.set_tooltip_text(self.apps.name(cls))
        return box

    def _window_menu(self, cls, anchor):
        wins = self.model.windows.get(cls, [])
        if not wins:
            return
        pop = Gtk.Popover()
        pop.set_parent(anchor)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for w in wins:
            row = Gtk.Button(label=w["title"])
            row.add_css_class("winrow")
            row.add_css_class("flat")
            row.set_has_frame(False)

            def pick(_b, addr=w["address"]):
                self.hypr.bring_to_mainstage(addr, self.cfg["promoteOnPick"])
                pop.popdown()

            row.connect("clicked", pick)
            col.append(row)
        pop.set_child(col)
        pop.popup()


def _single_instance():
    """Hold an abstract unix socket so a second launch bows out quietly."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        s.bind("\0goldenspiral-chronobar")
    except OSError:
        raise SystemExit(0)
    return s  # keep it alive for the process lifetime


if __name__ == "__main__":
    _lock = _single_instance()
    Chronobar().run(None)
