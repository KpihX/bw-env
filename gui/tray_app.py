#!/usr/bin/python3
"""BW-ENV AppIndicator tray."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")

from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
MAIN_SH = ROOT / "main.sh"
CONTROL_CENTER = ROOT / "gui" / "control_center.py"
TRAY_PID_FILE = Path(f"/dev/shm/bw-env-tray-{Path.home().name}.pid")


class Backend:
    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        # timeout=10: prevents hanging bw-env calls from accumulating when the
        # vault server is temporarily unreachable (was causing 6h+ CPU leaks).
        return subprocess.run(
            ["bash", str(MAIN_SH), *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    def status(self) -> dict:
        result = self.run("status", "--json")
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "status failed")
        return json.loads(result.stdout)

    def action(self, command: str) -> None:
        result = self.run(command)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{command} failed")

    def open_control_center(self) -> None:
        subprocess.Popen(
            ["/usr/bin/python3", str(CONTROL_CENTER)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class TrayApp:
    def __init__(self) -> None:
        self.backend = Backend()
        self.indicator = AppIndicator3.Indicator.new(
            "bw-env-tray",
            "dialog-information",
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("BW-ENV")
        self.menu = Gtk.Menu()
        self.status_item = Gtk.MenuItem(label="Loading BW-ENV...")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)
        self.menu.append(Gtk.SeparatorMenuItem())

        self._add_item("Open Control Center", self.open_control_center)
        self._add_item("Unlock", lambda *_: self.run_action("unlock"))
        self._add_item("Sync", lambda *_: self.run_action("sync"))
        self._add_item("Lock", lambda *_: self.run_action("lock"))
        self.menu.append(Gtk.SeparatorMenuItem())
        self._add_item("Pause", lambda *_: self.run_action("pause"))
        self._add_item("Resume", lambda *_: self.run_action("resume"))
        self._add_item("Start Daemon", lambda *_: self.run_action("start"))
        self._add_item("Stop Daemon", lambda *_: self.run_action("stop"))
        self._add_item("Restart Daemon", lambda *_: self.run_action("restart"))
        self.menu.append(Gtk.SeparatorMenuItem())
        self._add_item("Quit Tray", self.quit)

        self.menu.show_all()
        self.indicator.set_menu(self.menu)
        self._write_pid()
        self.refresh()
        # 30s interval: each poll spawns bash + Node.js (bw status). 5s was
        # causing ~720 Node processes/hour and multi-GB RAM leak over time.
        GLib.timeout_add_seconds(30, self.refresh)
        signal.signal(signal.SIGTERM, self._handle_quit_signal)
        signal.signal(signal.SIGINT, self._handle_quit_signal)

    def _write_pid(self) -> None:
        TRAY_PID_FILE.write_text(str(os.getpid()))

    def _remove_pid(self) -> None:
        TRAY_PID_FILE.unlink(missing_ok=True)

    def _handle_quit_signal(self, *_args: object) -> None:
        self.quit()

    def _add_item(self, label: str, callback) -> None:
        item = Gtk.MenuItem(label=label)
        item.connect("activate", callback)
        self.menu.append(item)

    def open_control_center(self, *_args: object) -> None:
        self.backend.open_control_center()

    def run_action(self, command: str) -> None:
        def worker() -> None:
            try:
                self.backend.action(command)
            except Exception as exc:  # noqa: BLE001
                GLib.idle_add(self._set_error_label, str(exc))
                return
            GLib.idle_add(self.refresh)

        threading.Thread(target=worker, daemon=True).start()

    def _set_error_label(self, message: str) -> bool:
        self.status_item.set_label(f"BW-ENV error: {message}")
        self.indicator.set_icon_full("dialog-error", "BW-ENV error")
        GLib.timeout_add_seconds(5, self.refresh)
        return False

    def refresh(self) -> bool:
        try:
            status = self.backend.status()
        except subprocess.TimeoutExpired:
            self.status_item.set_label("BW-ENV: status timeout (vault unreachable?)")
            self.indicator.set_icon_full("dialog-warning", "BW-ENV timeout")
            return True
        except Exception as exc:  # noqa: BLE001
            self.status_item.set_label(f"BW-ENV error: {exc}")
            self.indicator.set_icon_full("dialog-error", "BW-ENV error")
            return True

        daemon = status["daemon"]
        vault = status["vault"]
        subscribers = status["subscribers"]

        state_text = f'{daemon["label"]} | Vault: {"Unlocked" if vault["unlocked"] else "Locked"}'
        details = (
            f'{state_text} | Last sync: {daemon["last_sync"]} | '
            f'Int: {len(subscribers["interactive"])} | '
            f'Non-int: {len(subscribers["non_interactive"])}'
        )
        self.status_item.set_label(details)

        icon_name = "dialog-error"
        if daemon["running"] and daemon["state"] != "PAUSED" and vault["unlocked"]:
            icon_name = "emblem-default"
        elif daemon["state"] == "PAUSED" or not vault["unlocked"]:
            icon_name = "dialog-warning"

        self.indicator.set_icon_full(icon_name, details)
        self.indicator.set_label("BW-ENV", "")
        self.indicator.set_title(details)
        return True

    def quit(self, *_args: object) -> None:
        self._remove_pid()
        Gtk.main_quit()

    def run(self) -> None:
        Gtk.main()


if __name__ == "__main__":
    TrayApp().run()
