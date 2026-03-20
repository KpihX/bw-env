#!/usr/bin/python3
"""BW-ENV GTK control center."""

from __future__ import annotations

import json
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

from gi.repository import Gdk, GLib, Gtk  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
MAIN_SH = ROOT / "main.sh"
POLL_MS = 3000

CSS = b"""
window {
  background: #0f141c;
  color: #e6edf7;
}
#root {
  background: #0f141c;
}
#panel,
#subpanel,
#settings-frame {
  background: #171d27;
  border: 1px solid #303c4f;
  border-radius: 12px;
}
#subpanel {
  background: #1c2330;
}
headerbar {
  background: #121923;
  border-bottom: 1px solid #303c4f;
}
headerbar title {
  color: #f8fafc;
}
button {
  background: #212b3a;
  color: #e6edf7;
  border: 1px solid #3a475d;
  border-radius: 10px;
  box-shadow: none;
}
button:hover {
  background: #2a3647;
}
entry,
combobox box,
combobox button,
textview,
textview text {
  background: #1b2431;
  color: #e6edf7;
  border-color: #344256;
}
notebook header tab {
  background: #1c2431;
  color: #9fb0c7;
  border-radius: 10px 10px 0 0;
  padding: 8px 14px;
}
notebook header tab:checked {
  background: #273244;
  color: #f8fafc;
}
.section-title {
  font-weight: 700;
  color: #f8fafc;
}
.value-label {
  color: #d8e1ee;
}
.muted {
  color: #97a6ba;
}
.badge {
  border-radius: 999px;
  padding: 8px 14px;
  color: #f8fafc;
  font-weight: 700;
}
.badge-ok {
  background: #1f9d69;
}
.badge-warn {
  background: #c8921b;
}
.badge-error {
  background: #c65368;
}
.badge-info {
  background: #4f8cff;
}
.badge-violet {
  background: #8667f2;
}
.badge-muted {
  background: #5f7087;
}
"""


class BwEnvBackend:
    """Thin subprocess bridge to the shell backend."""

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(MAIN_SH), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def status(self) -> dict:
        result = self.run("status", "--json")
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "status failed")
        return json.loads(result.stdout)

    def config(self) -> dict:
        result = self.run("config", "list", "--json")
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "config list failed")
        return json.loads(result.stdout)

    def set_config(self, key: str, value: str) -> None:
        result = self.run("config", "set", key, value)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"config set failed for {key}")

    def action(self, command: str) -> None:
        result = self.run(command)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{command} failed")


class ControlCenter(Gtk.Window):
    """Main GTK control-center window."""

    def __init__(self) -> None:
        super().__init__(title="BW-ENV")
        self.backend = BwEnvBackend()
        self.set_default_size(1180, 820)
        self.set_size_request(980, 680)
        self.connect("destroy", Gtk.main_quit)
        self._refresh_inflight = False
        self.badges: dict[str, Gtk.Label] = {}
        self.value_labels: dict[str, Gtk.Label] = {}
        self.settings_widgets: dict[str, Gtk.Widget] = {}

        self._install_css()
        self._build_ui()
        self.refresh()
        GLib.timeout_add(POLL_MS, self.refresh)

    def _install_css(self) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _build_ui(self) -> None:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.set_name("root")
        root.set_border_width(16)
        self.add(root)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title("BW-ENV")
        self.set_titlebar(header)

        actions = Gtk.Box(spacing=8)
        for label, command in [
            ("Unlock", "unlock"),
            ("Sync", "sync"),
            ("Lock", "lock"),
            ("Pause", "pause"),
            ("Resume", "resume"),
            ("Start", "start"),
            ("Stop", "stop"),
            ("Restart", "restart"),
            ("Refresh", "__refresh__"),
        ]:
            button = Gtk.Button(label=label)
            if command == "__refresh__":
                button.connect("clicked", lambda *_: self.refresh())
            else:
                button.connect("clicked", lambda _btn, cmd=command: self.run_action(cmd))
            actions.pack_start(button, False, False, 0)
        root.pack_start(actions, False, False, 0)

        notebook = Gtk.Notebook()
        root.pack_start(notebook, True, True, 0)

        notebook.append_page(self._build_overview_tab(), Gtk.Label(label="Overview"))
        notebook.append_page(self._build_subscribers_tab(), Gtk.Label(label="Subscribers"))
        notebook.append_page(self._build_settings_tab(), Gtk.Label(label="Settings"))

    def _build_overview_tab(self) -> Gtk.Widget:
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)

        badges_frame = self._frame("Status Badges")
        badges_box = Gtk.FlowBox()
        badges_box.set_max_children_per_line(8)
        badges_box.set_selection_mode(Gtk.SelectionMode.NONE)
        badges_box.set_column_spacing(10)
        badges_box.set_row_spacing(10)
        badges_box.set_homogeneous(True)

        for key in ["Daemon", "Vault", "RAM", "Disk", "Shared", "GPG", "Subscribers", "Keys"]:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            title = Gtk.Label(label=key)
            title.get_style_context().add_class("muted")
            title.set_xalign(0.5)
            badge = Gtk.Label(label="...")
            badge.get_style_context().add_class("badge")
            badge.get_style_context().add_class("badge-muted")
            self.badges[key.lower()] = badge
            box.pack_start(title, False, False, 0)
            box.pack_start(badge, False, False, 0)
            badges_box.add(box)

        badges_frame.add(badges_box)
        outer.pack_start(badges_frame, False, False, 0)

        top = Gtk.Paned.new(Gtk.Orientation.HORIZONTAL)
        top.pack1(self._build_runtime_frame(), resize=True, shrink=False)
        top.pack2(self._build_storage_frame(), resize=True, shrink=False)
        outer.pack_start(top, False, False, 0)

        bottom = Gtk.Paned.new(Gtk.Orientation.HORIZONTAL)
        bottom.pack1(self._build_text_frame("Secrets", "keys"), resize=True, shrink=False)
        bottom.pack2(self._build_text_frame("Status Details", "details"), resize=True, shrink=False)
        outer.pack_start(bottom, True, True, 0)

        return outer

    def _build_runtime_frame(self) -> Gtk.Widget:
        frame = self._frame("Runtime")
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        for row, key in enumerate(["daemon", "vault", "last_sync", "interval", "concurrency"]):
            label = Gtk.Label(label=self._pretty_key(key) + ":")
            label.get_style_context().add_class("section-title")
            label.set_xalign(0)
            value = Gtk.Label(label="Loading...")
            value.get_style_context().add_class("value-label")
            value.set_xalign(0)
            value.set_line_wrap(True)
            self.value_labels[key] = value
            grid.attach(label, 0, row, 1, 1)
            grid.attach(value, 1, row, 1, 1)
        frame.add(grid)
        return frame

    def _build_storage_frame(self) -> Gtk.Widget:
        frame = self._frame("Storage & Bridges")
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        for row, key in enumerate(["ram_cache", "disk_cache", "shared_bridge", "gpg_bridge"]):
            label = Gtk.Label(label=self._pretty_key(key) + ":")
            label.get_style_context().add_class("section-title")
            label.set_xalign(0)
            value = Gtk.Label(label="Loading...")
            value.get_style_context().add_class("value-label")
            value.set_xalign(0)
            value.set_line_wrap(True)
            self.value_labels[key] = value
            grid.attach(label, 0, row, 1, 1)
            grid.attach(value, 1, row, 1, 1)
        frame.add(grid)
        return frame

    def _build_text_frame(self, title: str, key: str) -> Gtk.Widget:
        frame = self._frame(title)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        textview = Gtk.TextView()
        textview.set_wrap_mode(Gtk.WrapMode.WORD)
        textview.set_editable(False)
        textview.set_cursor_visible(False)
        textview.set_monospace(True)
        setattr(self, f"{key}_textview", textview)
        scrolled.add(textview)
        frame.add(scrolled)
        return frame

    def _build_subscribers_tab(self) -> Gtk.Widget:
        paned = Gtk.Paned.new(Gtk.Orientation.HORIZONTAL)
        paned.pack1(self._build_text_frame("Interactive Shells", "interactive"), resize=True, shrink=False)
        paned.pack2(self._build_text_frame("Non-Interactive Processes", "non_interactive"), resize=True, shrink=False)
        return paned

    def _build_settings_tab(self) -> Gtk.Widget:
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        scrolled.add(box)

        for section_title, keys in [
            ("Daemon", ["CHECK_INTERVAL", "MAX_AUTH_ATTEMPTS", "AUTO_START_ON_BOOT", "AUTO_START_ON_WAKE"]),
            ("Wake / UX", ["WAKE_DEBOUNCE_DELAY", "GRAPHICAL_WAIT_DELAY", "GRAPHICAL_WAIT_MAX"]),
            ("Concurrency / Shell", ["LOCK_TIMEOUT", "LOAD_WAIT_MAX", "LOAD_WAIT_STEP"]),
            ("Vault / Identity", ["ITEM_ID", "AUTHORIZED_USER", "CACHE_GPG"]),
            ("Logging", ["DAEMON_TAG", "LOG_TAG"]),
        ]:
            frame = self._frame(section_title, "settings-frame")
            grid = Gtk.Grid(column_spacing=14, row_spacing=10)
            for row, key in enumerate(keys):
                label = Gtk.Label(label=key)
                label.get_style_context().add_class("section-title")
                label.set_xalign(0)
                if key in {"AUTO_START_ON_BOOT", "AUTO_START_ON_WAKE"}:
                    widget = Gtk.ComboBoxText()
                    widget.append_text("true")
                    widget.append_text("false")
                else:
                    widget = Gtk.Entry()
                widget.set_hexpand(True)
                self.settings_widgets[key] = widget
                grid.attach(label, 0, row, 1, 1)
                grid.attach(widget, 1, row, 1, 1)
            frame.add(grid)
            box.pack_start(frame, False, False, 0)

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        reload_button = Gtk.Button(label="Reload")
        reload_button.connect("clicked", lambda *_: self.refresh())
        apply_button = Gtk.Button(label="Apply Settings")
        apply_button.connect("clicked", lambda *_: self.apply_settings())
        buttons.pack_end(apply_button, False, False, 0)
        buttons.pack_end(reload_button, False, False, 0)
        box.pack_start(buttons, False, False, 0)

        return scrolled

    def _frame(self, title: str, name: str = "panel") -> Gtk.Frame:
        frame = Gtk.Frame(label=title)
        frame.set_name(name)
        frame.set_shadow_type(Gtk.ShadowType.NONE)
        frame.set_margin_top(4)
        frame.set_margin_bottom(4)
        frame.set_margin_start(4)
        frame.set_margin_end(4)
        frame.set_label_align(0.03, 0.5)
        return frame

    def _pretty_key(self, key: str) -> str:
        return key.replace("_", " ").title()

    def _set_textview(self, name: str, text: str) -> None:
        textview: Gtk.TextView = getattr(self, f"{name}_textview")
        buffer_ = textview.get_buffer()
        buffer_.set_text(text)

    def _set_badge(self, key: str, text: str, css_class: str) -> None:
        badge = self.badges[key]
        badge.set_text(text)
        context = badge.get_style_context()
        for candidate in ["badge-ok", "badge-warn", "badge-error", "badge-info", "badge-violet", "badge-muted"]:
            context.remove_class(candidate)
        context.add_class(css_class)

    def refresh(self) -> bool:
        if self._refresh_inflight:
            return True
        self._refresh_inflight = True
        threading.Thread(target=self._refresh_worker, daemon=True).start()
        return True

    def _refresh_worker(self) -> None:
        try:
            status = self.backend.status()
            config = self.backend.config()
        except Exception as exc:  # noqa: BLE001
            GLib.idle_add(self._show_error, str(exc))
            self._refresh_inflight = False
            return

        GLib.idle_add(self._apply_refresh, status, config)

    def _apply_refresh(self, status: dict, config: dict) -> bool:
        daemon = status["daemon"]
        storage = status["storage"]
        keys = status["keys"]
        subscribers = status["subscribers"]

        self.value_labels["daemon"].set_text(
            daemon["label"] if daemon.get("pid") is None else f'{daemon["label"]} (PID {daemon["pid"]})'
        )
        self.value_labels["vault"].set_text("Unlocked" if status["vault"]["unlocked"] else "Locked")
        self.value_labels["last_sync"].set_text(daemon["last_sync"])
        self.value_labels["interval"].set_text(f'{daemon["check_interval"]} seconds')
        self.value_labels["concurrency"].set_text(status["concurrency"]["message"])
        self.value_labels["ram_cache"].set_text(self._storage_label(storage["ram_cache"]))
        self.value_labels["disk_cache"].set_text(self._storage_label(storage["disk_cache"]))
        self.value_labels["shared_bridge"].set_text(self._storage_label(storage["shared_bridge"]))
        self.value_labels["gpg_bridge"].set_text(self._storage_label(storage["gpg_bridge"]))

        self._set_badge(
            "daemon",
            daemon["label"],
            "badge-ok" if daemon["running"] and daemon["state"] != "PAUSED" else "badge-warn",
        )
        self._set_badge("vault", "Unlocked" if status["vault"]["unlocked"] else "Locked", "badge-ok" if status["vault"]["unlocked"] else "badge-error")
        self._set_badge("ram", "Active" if storage["ram_cache"]["active"] else "Off", "badge-ok" if storage["ram_cache"]["active"] else "badge-error")
        self._set_badge("disk", "Encrypted" if storage["disk_cache"]["active"] else "Missing", "badge-ok" if storage["disk_cache"]["active"] else "badge-error")
        self._set_badge("shared", "Active" if storage["shared_bridge"]["active"] else "Off", "badge-ok" if storage["shared_bridge"]["active"] else "badge-muted")
        self._set_badge("gpg", "Active" if storage["gpg_bridge"]["active"] else "Off", "badge-ok" if storage["gpg_bridge"]["active"] else "badge-muted")
        self._set_badge("subscribers", str(len(subscribers["interactive"]) + len(subscribers["non_interactive"])), "badge-info")
        self._set_badge("keys", str(keys["count"]), "badge-violet" if keys["count"] else "badge-muted")

        key_names = "\n".join(keys["names"]) if keys["names"] else "None"
        self._set_textview(
            "keys",
            "\n".join(
                [
                    f'Count: {keys["count"]}',
                    f'Active in RAM: {"yes" if keys["active_in_ram"] else "no"}',
                    "",
                    "Names:",
                    key_names,
                ]
            ),
        )
        self._set_textview(
            "interactive",
            "\n".join(f"- PID {pid}" for pid in subscribers["interactive"]) or "No interactive subscribers.",
        )
        non_interactive_lines = []
        for proc in subscribers["non_interactive"]:
            non_interactive_lines.append(
                f'- PID {proc["pid"]} | TTY {proc["tty"]} | Comm {proc["comm"]}\n  Cmd: {proc["args"]}'
            )
        self._set_textview("non_interactive", "\n\n".join(non_interactive_lines) or "No non-interactive subscribers.")
        self._set_textview(
            "details",
            "\n".join(
                [
                    f'Daemon PID: {daemon.get("pid")}',
                    f'Daemon state: {daemon["state"]}',
                    f'Last sync: {daemon["last_sync"]}',
                    f'Check interval: {daemon["check_interval"]} seconds',
                    f'Auto start on boot: {daemon["auto_start_on_boot"]}',
                    f'Auto start on wake: {daemon["auto_start_on_wake"]}',
                    f'Concurrency: {status["concurrency"]["state"]} | {status["concurrency"]["message"]}',
                    f'Interactive subscribers: {len(subscribers["interactive"])}',
                    f'Non-interactive subscribers: {len(subscribers["non_interactive"])}',
                    f'RAM cache path: {storage["ram_cache"]["path"]}',
                    f'Disk cache path: {storage["disk_cache"]["path"]}',
                    f'Shared bridge path: {storage["shared_bridge"]["path"]}',
                    f'GPG bridge path: {storage["gpg_bridge"]["path"]}',
                ]
            ),
        )

        current_map = {
            "AUTHORIZED_USER": config["authorized_user"],
            "ITEM_ID": config["item_id"],
            "CACHE_GPG": config["cache_gpg"],
            "CHECK_INTERVAL": str(config["daemon"]["check_interval"]),
            "MAX_AUTH_ATTEMPTS": str(config["daemon"]["max_auth_attempts"]),
            "AUTO_START_ON_BOOT": "true" if config["daemon"]["auto_start_on_boot"] else "false",
            "AUTO_START_ON_WAKE": "true" if config["daemon"]["auto_start_on_wake"] else "false",
            "WAKE_DEBOUNCE_DELAY": str(config["daemon"]["wake_debounce_delay"]),
            "GRAPHICAL_WAIT_DELAY": str(config["daemon"]["graphical_wait_delay"]),
            "GRAPHICAL_WAIT_MAX": str(config["daemon"]["graphical_wait_max"]),
            "LOCK_TIMEOUT": str(config["daemon"]["lock_timeout"]),
            "LOAD_WAIT_MAX": str(config["daemon"]["load_wait_max"]),
            "LOAD_WAIT_STEP": str(config["daemon"]["load_wait_step"]),
            "DAEMON_TAG": config["logging"]["daemon_tag"],
            "LOG_TAG": config["logging"]["log_tag"],
        }

        for key, widget in self.settings_widgets.items():
            value = current_map[key]
            if isinstance(widget, Gtk.ComboBoxText):
                widget.set_active(0 if value == "true" else 1)
            elif isinstance(widget, Gtk.Entry):
                widget.set_text(value)

        self._refresh_inflight = False
        return False

    def _storage_label(self, payload: dict) -> str:
        state = "Active" if payload["active"] else "Inactive"
        return f'{state} ({payload["path"]})'

    def _show_error(self, message: str) -> bool:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.CLOSE,
            text="BW-ENV",
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()
        return False

    def _show_info(self, message: str) -> bool:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.CLOSE,
            text="BW-ENV",
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()
        return False

    def run_action(self, command: str) -> None:
        def worker() -> None:
            try:
                self.backend.action(command)
            except Exception as exc:  # noqa: BLE001
                GLib.idle_add(self._show_error, str(exc))
                return
            GLib.idle_add(self.refresh)

        threading.Thread(target=worker, daemon=True).start()

    def apply_settings(self) -> None:
        def worker() -> None:
            try:
                current = self.backend.config()
                current_map = {
                    "AUTHORIZED_USER": current["authorized_user"],
                    "ITEM_ID": current["item_id"],
                    "CACHE_GPG": current["cache_gpg"],
                    "CHECK_INTERVAL": str(current["daemon"]["check_interval"]),
                    "MAX_AUTH_ATTEMPTS": str(current["daemon"]["max_auth_attempts"]),
                    "AUTO_START_ON_BOOT": "true" if current["daemon"]["auto_start_on_boot"] else "false",
                    "AUTO_START_ON_WAKE": "true" if current["daemon"]["auto_start_on_wake"] else "false",
                    "WAKE_DEBOUNCE_DELAY": str(current["daemon"]["wake_debounce_delay"]),
                    "GRAPHICAL_WAIT_DELAY": str(current["daemon"]["graphical_wait_delay"]),
                    "GRAPHICAL_WAIT_MAX": str(current["daemon"]["graphical_wait_max"]),
                    "LOCK_TIMEOUT": str(current["daemon"]["lock_timeout"]),
                    "LOAD_WAIT_MAX": str(current["daemon"]["load_wait_max"]),
                    "LOAD_WAIT_STEP": str(current["daemon"]["load_wait_step"]),
                    "DAEMON_TAG": current["logging"]["daemon_tag"],
                    "LOG_TAG": current["logging"]["log_tag"],
                }

                for key, widget in self.settings_widgets.items():
                    if isinstance(widget, Gtk.ComboBoxText):
                        value = widget.get_active_text() or ""
                    else:
                        value = widget.get_text().strip()
                    if value != current_map.get(key, ""):
                        self.backend.set_config(key, value)
            except Exception as exc:  # noqa: BLE001
                GLib.idle_add(self._show_error, str(exc))
                return

            GLib.idle_add(self._show_info, "Settings updated.")
            GLib.idle_add(self.refresh)

        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    win = ControlCenter()
    win.show_all()
    Gtk.main()
