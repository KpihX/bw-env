#!/usr/bin/env python3
"""BW-ENV control center."""

from __future__ import annotations

import json
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk


ROOT = Path(__file__).resolve().parents[1]
MAIN_SH = ROOT / "main.sh"
POLL_MS = 3000


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


class ControlCenter:
    """Main control-center window."""

    def __init__(self) -> None:
        self.backend = BwEnvBackend()
        self.root = tk.Tk()
        self.root.title("BW-ENV")
        self.root.geometry("1120x760")
        self.root.minsize(960, 640)
        self.palette = {
            "bg": "#11161d",
            "panel": "#171d27",
            "panel_alt": "#1f2836",
            "border": "#344256",
            "text": "#e6edf7",
            "muted": "#97a6ba",
            "green": "#1f9d69",
            "amber": "#c8921b",
            "red": "#c65368",
            "blue": "#4f8cff",
            "violet": "#8667f2",
            "gray": "#5f7087",
        }
        self.root.configure(bg=self.palette["bg"])
        self._configure_styles()

        self.status_vars = {
            "daemon": tk.StringVar(value="Loading..."),
            "vault": tk.StringVar(value="Loading..."),
            "last_sync": tk.StringVar(value="Loading..."),
            "interval": tk.StringVar(value="Loading..."),
            "concurrency": tk.StringVar(value="Loading..."),
            "ram_cache": tk.StringVar(value="Loading..."),
            "disk_cache": tk.StringVar(value="Loading..."),
            "shared_bridge": tk.StringVar(value="Loading..."),
            "gpg_bridge": tk.StringVar(value="Loading..."),
            "keys": tk.StringVar(value="Loading..."),
            "details": tk.StringVar(value="Loading..."),
        }
        self.settings_vars: dict[str, tk.StringVar] = {}
        self.badges: dict[str, tk.Label] = {}
        self._refresh_scheduled = False

        self._build_ui()
        self.refresh()

    def _configure_styles(self) -> None:
        style = ttk.Style()
        style.theme_use("clam")
        style.configure(".", background=self.palette["bg"], foreground=self.palette["text"])
        style.configure("TFrame", background=self.palette["bg"])
        style.configure("TLabel", background=self.palette["bg"], foreground=self.palette["text"])
        style.configure("TLabelframe", background=self.palette["panel"], foreground=self.palette["text"], bordercolor=self.palette["border"])
        style.configure("TLabelframe.Label", background=self.palette["panel"], foreground=self.palette["text"])
        style.configure("TButton", background=self.palette["panel_alt"], foreground=self.palette["text"], bordercolor=self.palette["border"], focusthickness=0)
        style.map("TButton", background=[("active", self.palette["border"])])
        style.configure("TNotebook", background=self.palette["bg"], borderwidth=0)
        style.configure("TNotebook.Tab", background=self.palette["panel_alt"], foreground=self.palette["text"], padding=(14, 8))
        style.map(
            "TNotebook.Tab",
            background=[("selected", self.palette["panel"])],
            foreground=[("selected", self.palette["text"])],
        )
        style.configure(
            "TEntry",
            fieldbackground=self.palette["panel_alt"],
            foreground=self.palette["text"],
            insertcolor=self.palette["text"],
            bordercolor=self.palette["border"],
        )
        style.configure(
            "TCombobox",
            fieldbackground=self.palette["panel_alt"],
            background=self.palette["panel_alt"],
            foreground=self.palette["text"],
            arrowcolor=self.palette["text"],
            bordercolor=self.palette["border"],
        )
        style.map(
            "TCombobox",
            fieldbackground=[("readonly", self.palette["panel_alt"])],
            background=[("readonly", self.palette["panel_alt"])],
            foreground=[("readonly", self.palette["text"])],
            selectbackground=[("readonly", self.palette["panel_alt"])],
            selectforeground=[("readonly", self.palette["text"])],
            arrowcolor=[("readonly", self.palette["text"])],
        )
        self.root.option_add("*TCombobox*Listbox.background", self.palette["panel_alt"])
        self.root.option_add("*TCombobox*Listbox.foreground", self.palette["text"])
        self.root.option_add("*TCombobox*Listbox.selectBackground", self.palette["blue"])
        self.root.option_add("*TCombobox*Listbox.selectForeground", self.palette["text"])

    def _build_ui(self) -> None:
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)

        header = ttk.Frame(self.root, padding=16)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)

        title = tk.Label(
            header,
            text="BW-ENV",
            font=("TkDefaultFont", 22, "bold"),
            bg=self.palette["bg"],
            fg=self.palette["text"],
        )
        title.grid(row=0, column=0, sticky="w")

        actions = ttk.Frame(header)
        actions.grid(row=1, column=0, sticky="ew", pady=(12, 0))

        for idx, (label, command) in enumerate(
            [
                ("Unlock", "unlock"),
                ("Sync", "sync"),
                ("Lock", "lock"),
                ("Pause", "pause"),
                ("Resume", "resume"),
                ("Start", "start"),
                ("Stop", "stop"),
                ("Restart", "restart"),
                ("Refresh", "__refresh__"),
            ]
        ):
            callback = self.refresh if command == "__refresh__" else lambda cmd=command: self.run_action(cmd)
            ttk.Button(actions, text=label, command=callback).grid(row=0, column=idx, padx=(0, 8))

        notebook = ttk.Notebook(self.root)
        notebook.grid(row=1, column=0, sticky="nsew", padx=16, pady=(0, 16))

        self.overview_tab = ttk.Frame(notebook, padding=16)
        self.subscribers_tab = ttk.Frame(notebook, padding=16)
        self.settings_tab = ttk.Frame(notebook, padding=16)

        notebook.add(self.overview_tab, text="Overview")
        notebook.add(self.subscribers_tab, text="Subscribers")
        notebook.add(self.settings_tab, text="Settings")

        self._build_overview_tab()
        self._build_subscribers_tab()
        self._build_settings_tab()

    def _build_overview_tab(self) -> None:
        self.overview_tab.columnconfigure(0, weight=1)
        self.overview_tab.columnconfigure(1, weight=2)
        self.overview_tab.rowconfigure(2, weight=1)

        badges = ttk.LabelFrame(self.overview_tab, text="Status Badges", padding=16)
        badges.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))

        for idx, label in enumerate(["Daemon", "Vault", "RAM", "Disk", "Shared", "GPG", "Subscribers", "Keys"]):
            container = ttk.Frame(badges)
            container.grid(row=0, column=idx, padx=6, sticky="nsew")
            ttk.Label(container, text=label).grid(row=0, column=0, sticky="ew")
            badge = tk.Label(
                container,
                text="...",
                bg=self.palette["gray"],
                fg=self.palette["text"],
                padx=12,
                pady=6,
                relief="ridge",
                bd=1,
            )
            badge.grid(row=1, column=0, sticky="ew", pady=(6, 0))
            self.badges[label.lower()] = badge

        runtime = ttk.LabelFrame(self.overview_tab, text="Runtime", padding=16)
        runtime.grid(row=1, column=0, sticky="nsew", padx=(0, 8), pady=(0, 8))
        runtime.columnconfigure(1, weight=1)

        self._add_kv(runtime, 0, "Daemon", self.status_vars["daemon"])
        self._add_kv(runtime, 1, "Vault", self.status_vars["vault"])
        self._add_kv(runtime, 2, "Last Sync", self.status_vars["last_sync"])
        self._add_kv(runtime, 3, "Sync Interval", self.status_vars["interval"])
        self._add_kv(runtime, 4, "Concurrency", self.status_vars["concurrency"])

        storage = ttk.LabelFrame(self.overview_tab, text="Storage & Bridges", padding=16)
        storage.grid(row=1, column=1, sticky="nsew", padx=(8, 0), pady=(0, 8))
        storage.columnconfigure(1, weight=1)

        self._add_kv(storage, 0, "RAM Cache", self.status_vars["ram_cache"])
        self._add_kv(storage, 1, "Disk Cache", self.status_vars["disk_cache"])
        self._add_kv(storage, 2, "Shared Bridge", self.status_vars["shared_bridge"])
        self._add_kv(storage, 3, "GPG Bridge", self.status_vars["gpg_bridge"])

        keys = ttk.LabelFrame(self.overview_tab, text="Secrets", padding=16)
        keys.grid(row=2, column=0, sticky="nsew", padx=(0, 8), pady=(8, 0))
        keys.columnconfigure(0, weight=1)
        keys.rowconfigure(0, weight=1)

        self.keys_text = tk.Text(
            keys,
            wrap="word",
            height=14,
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            relief="flat",
            padx=12,
            pady=12,
        )
        self.keys_text.grid(row=0, column=0, sticky="nsew")
        self.keys_text.configure(state="disabled")

        details = ttk.LabelFrame(self.overview_tab, text="Status Details", padding=16)
        details.grid(row=2, column=1, sticky="nsew", padx=(8, 0), pady=(8, 0))
        details.columnconfigure(0, weight=1)
        details.rowconfigure(0, weight=1)

        self.details_text = tk.Text(details, wrap="word", height=14)
        self.details_text.grid(row=0, column=0, sticky="nsew")
        self.details_text.configure(
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            relief="flat",
            padx=12,
            pady=12,
        )
        self.details_text.configure(state="disabled")

    def _build_subscribers_tab(self) -> None:
        self.subscribers_tab.columnconfigure(0, weight=1)
        self.subscribers_tab.columnconfigure(1, weight=1)
        self.subscribers_tab.rowconfigure(0, weight=1)

        interactive_frame = ttk.LabelFrame(self.subscribers_tab, text="Interactive Shells", padding=12)
        interactive_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        interactive_frame.rowconfigure(0, weight=1)
        interactive_frame.columnconfigure(0, weight=1)

        non_interactive_frame = ttk.LabelFrame(self.subscribers_tab, text="Non-Interactive Processes", padding=12)
        non_interactive_frame.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        non_interactive_frame.rowconfigure(0, weight=1)
        non_interactive_frame.columnconfigure(0, weight=1)

        self.interactive_text = tk.Text(interactive_frame, wrap="word", height=20)
        self.interactive_text.grid(row=0, column=0, sticky="nsew")
        self.interactive_text.configure(
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            relief="flat",
            padx=12,
            pady=12,
        )
        self.interactive_text.configure(state="disabled")

        self.non_interactive_text = tk.Text(non_interactive_frame, wrap="word", height=20)
        self.non_interactive_text.grid(row=0, column=0, sticky="nsew")
        self.non_interactive_text.configure(
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            relief="flat",
            padx=12,
            pady=12,
        )
        self.non_interactive_text.configure(state="disabled")

    def _build_settings_tab(self) -> None:
        self.settings_tab.columnconfigure(0, weight=1)
        self.settings_tab.rowconfigure(0, weight=1)

        container = ttk.Frame(self.settings_tab)
        container.grid(row=0, column=0, sticky="nsew")
        container.columnconfigure(0, weight=1)
        container.rowconfigure(0, weight=1)

        canvas = tk.Canvas(
            container,
            bg=self.palette["bg"],
            highlightthickness=0,
            bd=0,
        )
        scrollbar = ttk.Scrollbar(container, orient="vertical", command=canvas.yview)
        frame = ttk.Frame(canvas)
        frame.columnconfigure(1, weight=1)

        frame.bind(
            "<Configure>",
            lambda event: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas_window = canvas.create_window((0, 0), window=frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        scrollbar.grid(row=0, column=1, sticky="ns")
        canvas.bind(
            "<Configure>",
            lambda event: canvas.itemconfigure(canvas_window, width=event.width),
        )

        def _on_mousewheel(event: tk.Event) -> None:
            delta = -1 * int(event.delta / 120) if event.delta else 0
            canvas.yview_scroll(delta or -1, "units")

        canvas.bind_all("<MouseWheel>", _on_mousewheel)

        grouped_settings = [
            ("Daemon", ["CHECK_INTERVAL", "MAX_AUTH_ATTEMPTS", "AUTO_START_ON_BOOT", "AUTO_START_ON_WAKE"]),
            ("Wake / UX", ["WAKE_DEBOUNCE_DELAY", "GRAPHICAL_WAIT_DELAY", "GRAPHICAL_WAIT_MAX"]),
            ("Concurrency / Shell", ["LOCK_TIMEOUT", "LOAD_WAIT_MAX", "LOAD_WAIT_STEP"]),
            ("Vault / Identity", ["ITEM_ID", "AUTHORIZED_USER", "CACHE_GPG"]),
            ("Logging", ["DAEMON_TAG", "LOG_TAG"]),
        ]

        row = 0
        for title, keys in grouped_settings:
            section = ttk.LabelFrame(frame, text=title, padding=12)
            section.grid(row=row, column=0, sticky="ew", pady=(0, 10))
            section.columnconfigure(1, weight=1)
            for idx, key in enumerate(keys):
                ttk.Label(section, text=key).grid(row=idx, column=0, sticky="w", padx=(0, 12), pady=4)
                var = tk.StringVar()
                self.settings_vars[key] = var
                if key in {"AUTO_START_ON_BOOT", "AUTO_START_ON_WAKE"}:
                    widget = ttk.Combobox(section, textvariable=var, values=["true", "false"], state="readonly")
                    widget.configure(takefocus=False)
                else:
                    widget = ttk.Entry(section, textvariable=var)
                widget.grid(row=idx, column=1, sticky="ew", pady=4)
            row += 1

        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, sticky="e", pady=(8, 0))
        ttk.Button(buttons, text="Reload", command=self.refresh).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(buttons, text="Apply Settings", command=self.apply_settings).grid(row=0, column=1)

    def _add_kv(self, parent: ttk.Frame, row: int, label: str, var: tk.StringVar) -> None:
        ttk.Label(parent, text=f"{label}:", font=("TkDefaultFont", 10, "bold")).grid(
            row=row, column=0, sticky="nw", padx=(0, 12), pady=4
        )
        ttk.Label(parent, textvariable=var, justify="left", anchor="w").grid(row=row, column=1, sticky="ew", pady=4)

    def refresh(self) -> None:
        if self._refresh_scheduled:
            return
        self._refresh_scheduled = True
        threading.Thread(target=self._refresh_worker, daemon=True).start()

    def _refresh_worker(self) -> None:
        try:
            status = self.backend.status()
            config = self.backend.config()
        except Exception as exc:  # noqa: BLE001
            self.root.after(0, lambda: messagebox.showerror("BW-ENV", str(exc)))
            self._refresh_scheduled = False
            self.root.after(POLL_MS, self.refresh)
            return

        self.root.after(0, lambda: self._apply_refresh(status, config))

    def _apply_refresh(self, status: dict, config: dict) -> None:
        daemon = status["daemon"]
        storage = status["storage"]
        keys = status["keys"]
        subscribers = status["subscribers"]

        daemon_text = daemon["label"]
        if daemon.get("pid") is not None:
            daemon_text = f'{daemon_text} (PID {daemon["pid"]})'
        self.status_vars["daemon"].set(daemon_text)
        self.status_vars["vault"].set("Unlocked" if status["vault"]["unlocked"] else "Locked")
        self.status_vars["last_sync"].set(daemon["last_sync"])
        self.status_vars["interval"].set(f'{daemon["check_interval"]} seconds')
        self.status_vars["concurrency"].set(status["concurrency"]["message"])
        self.status_vars["ram_cache"].set(self._storage_label(storage["ram_cache"]))
        self.status_vars["disk_cache"].set(self._storage_label(storage["disk_cache"]))
        self.status_vars["shared_bridge"].set(self._storage_label(storage["shared_bridge"]))
        self.status_vars["gpg_bridge"].set(self._storage_label(storage["gpg_bridge"]))
        key_names = ", ".join(keys["names"]) if keys["names"] else "None"
        self._set_text(
            self.keys_text,
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
        self._update_badges(status)

        self._set_text(
            self.interactive_text,
            "\n".join(f"- PID {pid}" for pid in subscribers["interactive"]) or "No interactive subscribers.",
        )

        non_interactive_lines = []
        for proc in subscribers["non_interactive"]:
            non_interactive_lines.append(
                f'- PID {proc["pid"]} | TTY {proc["tty"]} | Comm {proc["comm"]}\n  Cmd: {proc["args"]}'
            )
        self._set_text(
            self.non_interactive_text,
            "\n\n".join(non_interactive_lines) or "No non-interactive subscribers.",
        )
        detail_lines = [
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
        self._set_text(self.details_text, "\n".join(detail_lines))

        flat_config = {
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
        for key, value in flat_config.items():
            if key in self.settings_vars:
                self.settings_vars[key].set(value)

        self._refresh_scheduled = False
        self.root.after(POLL_MS, self.refresh)

    def _storage_label(self, payload: dict) -> str:
        state = "Active" if payload["active"] else "Inactive"
        return f'{state} ({payload["path"]})'

    def _update_badges(self, status: dict) -> None:
        daemon = status["daemon"]
        storage = status["storage"]
        subscribers = status["subscribers"]
        keys = status["keys"]

        self._set_badge("daemon", daemon["label"], "#16a34a" if daemon["running"] and daemon["state"] != "PAUSED" else "#f59e0b")
        self._set_badge("vault", "Unlocked" if status["vault"]["unlocked"] else "Locked", self.palette["green"] if status["vault"]["unlocked"] else self.palette["red"])
        self._set_badge("ram", "Active" if storage["ram_cache"]["active"] else "Off", self.palette["green"] if storage["ram_cache"]["active"] else self.palette["red"])
        self._set_badge("disk", "Encrypted" if storage["disk_cache"]["active"] else "Missing", self.palette["green"] if storage["disk_cache"]["active"] else self.palette["red"])
        self._set_badge("shared", "Active" if storage["shared_bridge"]["active"] else "Off", self.palette["green"] if storage["shared_bridge"]["active"] else self.palette["gray"])
        self._set_badge("gpg", "Active" if storage["gpg_bridge"]["active"] else "Off", self.palette["green"] if storage["gpg_bridge"]["active"] else self.palette["gray"])
        self._set_badge("subscribers", str(len(subscribers["interactive"]) + len(subscribers["non_interactive"])), self.palette["blue"])
        self._set_badge("keys", str(keys["count"]), self.palette["violet"] if keys["count"] else self.palette["gray"])

    def _set_badge(self, key: str, text: str, color: str) -> None:
        badge = self.badges[key]
        badge.configure(text=text, bg=color, fg="white")

    def _set_text(self, widget: tk.Text, value: str) -> None:
        widget.configure(state="normal")
        widget.delete("1.0", tk.END)
        widget.insert("1.0", value)
        widget.configure(state="disabled")

    def run_action(self, command: str) -> None:
        def worker() -> None:
            try:
                self.backend.action(command)
            except Exception as exc:  # noqa: BLE001
                self.root.after(0, lambda: messagebox.showerror("BW-ENV", str(exc)))
                return
            self.root.after(0, self.refresh)

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
                for key, var in self.settings_vars.items():
                    value = var.get().strip()
                    if value != current_map.get(key, ""):
                        self.backend.set_config(key, value)
            except Exception as exc:  # noqa: BLE001
                self.root.after(0, lambda: messagebox.showerror("BW-ENV", str(exc)))
                return

            self.root.after(0, lambda: messagebox.showinfo("BW-ENV", "Settings updated."))
            self.root.after(0, self.refresh)

        threading.Thread(target=worker, daemon=True).start()

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    ControlCenter().run()
