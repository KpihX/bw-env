# === BW-ENV MAKEFILE ===
# Automates the full project lifecycle for bw-env (shell script project).
# Usage: make <target>

BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
SHELL_SCRIPTS := shell.sh load.sh main.sh sync-daemon.sh utils.sh profile.sh

.PHONY: help push push-tags check lint log status install purge

# Default target
help:
	@echo ""
	@echo "bw-env — available targets:"
	@echo ""
	@echo "  install     Install bw-env on this machine (interactive)
  install-y   Install bw-env with all defaults (-y flag)
  purge       Uninstall bw-env from this machine (interactive)
  purge-y     Uninstall bw-env silently (-y flag)
  push        Push current branch ($(BRANCH)) to github + gitlab"
	@echo "  push-tags   Push all tags to github + gitlab (triggers CI releases)"
	@echo "  check       Bash syntax check (bash -n) on all .sh files"
	@echo "  lint        Shellcheck lint (requires: apt install shellcheck)"
	@echo "  log         Show recent git log (last 10 commits)"
	@echo "  status      Show git status + diff summary"
	@echo ""

# ─── Install / Uninstall ──────────────────────────────────────────────────────

install:
	bash install.sh

install-y:
	bash install.sh -y

purge:
	bash purge.sh

purge-y:
	bash purge.sh -y

# ─── Git ───────────────────────────────────────────────────────────────────────

push:
	git push github $(BRANCH)
	git push gitlab $(BRANCH)

push-tags:
	git push github --tags
	git push gitlab --tags

log:
	git log --oneline -10

status:
	git status
	git diff --stat

# ─── Quality ───────────────────────────────────────────────────────────────────

check:
	@echo "=== Bash syntax check ==="
	@for f in $(SHELL_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found — install with: sudo apt install shellcheck"; exit 1; }
	shellcheck --shell=bash $(SHELL_SCRIPTS)
