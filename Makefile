# === BW-ENV MAKEFILE ===
# Finalized v2.0.1 — Phoenix Protocol

SHELL_SCRIPTS := shell.sh load.sh main.sh sync-daemon.sh utils.sh profile.sh

.PHONY: help push status install purge log check lint

# Default target
help: ## Show this help
	@echo ""
	@echo "bw-env — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

install: ## Install bw-env on this machine (interactive)
	@bash install.sh

install-y: ## Install bw-env with all defaults (-y flag)
	@bash install.sh -y

purge: ## Uninstall bw-env from this machine (interactive)
	@bash purge.sh

purge-y: ## Uninstall bw-env silently (-y flag)
	@bash purge.sh -y

# ─── Status & Logs ──────────────────────────────────────────────────────────
status: ## Show bw-env sync + tray service status (user systemd)
	@bash main.sh status

log: ## Show sync daemon logs
	@journalctl --user -u bw-env-sync.service -n 50 --no-pager

# ─── Git & Quality ───────────────────────────────────────────────────────────
push: ## Push current branch to github + gitlab
	@branch="$$(git branch --show-current)"; \
	git push github "$$branch" && git push gitlab "$$branch"

git-status: ## git status + diff summary
	@git status && git diff --stat

check: ## Bash syntax check (bash -n) on all .sh files
	@echo "=== Bash syntax check ==="
	@for f in $(SHELL_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done

lint: ## Shellcheck lint
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck missing (sudo apt install shellcheck)"; exit 1; }
	@shellcheck --shell=bash $(SHELL_SCRIPTS)
