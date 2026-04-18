#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
DEFAULT_REPO_DIR="$HOME/Developer/GitHub/alfred"
REPO_DIR="${ALFRED_REPO_DIR:-$DEFAULT_REPO_DIR}"
case "$(uname -s)" in
  Darwin) DEFAULT_DATA_DIR="$HOME/Library/Application Support/Alfred" ;;
  *)      DEFAULT_DATA_DIR="$HOME/.local/share/alfred" ;;
esac
DATA_DIR="${ALFRED_DATA_DIR:-$DEFAULT_DATA_DIR}"
REPO_SLUG="${ALFRED_REPO_SLUG:-sinapsysxyz/alfred}"
BRANCH="${ALFRED_REPO_BRANCH:-main}"
MODE="prod"
INSTALL_LAUNCHD=0
FRESH_DB=0
MIGRATE_DB_PATH=""
SKIP_OPENCLAW_WIZARD=0
PRINT_SUMMARY_ONLY=0
TELEGRAM_TOKEN_FILE=""

say() {
  printf '[alfred-install] %s\n' "$*"
}

fail() {
  printf '[alfred-install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Canonical Alfred installer entrypoint for a fresh machine or an existing checkout.
It authenticates with GitHub if needed, clones the private Alfred repo, then hands off
to Alfred's repo-local installer.

Options:
  --repo-dir PATH         Target repo path (default: $DEFAULT_REPO_DIR)
  --data-dir PATH         Alfred runtime data dir
  --branch NAME           Git branch to clone or refresh (default: $BRANCH)
  --dev                   Install for local development workflow
  --launchd               Generate and install a per-user LaunchAgent, then load it
  --fresh-db              Initialize a fresh local DB when none exists
  --migrate-db PATH       Copy an existing SQLite DB into Alfred runtime if target DB is absent
  --skip-openclaw-wizard  Provision OpenClaw workspace but skip the interactive email/Telegram wizard (CI)
  --telegram-token-file PATH
                          Non-interactive Telegram setup: read the bot token from PATH.
                          Alternative: export TELEGRAM_BOT_TOKEN in the environment.
  --summary               Print resolved install plan and exit
  --help, -h              Show this help

Environment:
  GITHUB_TOKEN            GitHub token with read access to $REPO_SLUG
  TELEGRAM_BOT_TOKEN      Telegram bot token (alternative to --telegram-token-file)
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1. Install prerequisites with: brew install git node@22 pnpm"
}

can_prompt() {
  [ -t 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

ensure_github_cli() {
  if command -v gh >/dev/null 2>&1; then
    return
  fi

  command -v brew >/dev/null 2>&1 || fail "GitHub CLI is required to fetch the private Alfred repo. Install Homebrew and run 'brew install gh', or install gh manually."

  say "Installing GitHub CLI via Homebrew"
  brew install gh
}

ensure_github_auth() {
  if gh auth status >/dev/null 2>&1; then
    say "GitHub CLI already authenticated"
    gh auth setup-git >/dev/null 2>&1 || true
    return
  fi

  if [ -z "$GITHUB_TOKEN" ]; then
    if ! can_prompt; then
      fail "GitHub authentication is required to fetch $REPO_SLUG. Re-run with GITHUB_TOKEN set to a token that has repo read access."
    fi

    printf '  GitHub token for %s: ' "$REPO_SLUG" > /dev/tty
    read -rs GITHUB_TOKEN < /dev/tty || true
    printf '\n' > /dev/tty

    [ -n "$GITHUB_TOKEN" ] || fail "GitHub token is required to fetch the private Alfred repo."
  fi

  say "Authenticating GitHub CLI"
  gh auth login --hostname github.com --with-token <<< "$GITHUB_TOKEN" >/dev/null
  gh auth setup-git >/dev/null 2>&1 || true
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir)
      shift
      REPO_DIR="${1:-}"
      ;;
    --data-dir)
      shift
      DATA_DIR="${1:-}"
      ;;
    --branch)
      shift
      BRANCH="${1:-}"
      ;;
    --dev)
      MODE="dev"
      ;;
    --launchd)
      INSTALL_LAUNCHD=1
      ;;
    --fresh-db)
      FRESH_DB=1
      ;;
    --migrate-db)
      shift
      MIGRATE_DB_PATH="${1:-}"
      ;;
    --skip-openclaw-wizard)
      SKIP_OPENCLAW_WIZARD=1
      ;;
    --telegram-token-file)
      shift
      TELEGRAM_TOKEN_FILE="${1:-}"
      ;;
    --summary)
      PRINT_SUMMARY_ONLY=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

[ -n "$REPO_DIR" ] || fail "Repo dir cannot be empty"
[ -n "$DATA_DIR" ] || fail "Data dir cannot be empty"

if [ "$FRESH_DB" -eq 1 ] && [ -n "$MIGRATE_DB_PATH" ]; then
  fail "Choose either --fresh-db or --migrate-db PATH, not both"
fi

if [ -n "$MIGRATE_DB_PATH" ] && [ ! -f "$MIGRATE_DB_PATH" ]; then
  fail "Migration source not found: $MIGRATE_DB_PATH"
fi

if [ -n "$TELEGRAM_TOKEN_FILE" ] && [ ! -r "$TELEGRAM_TOKEN_FILE" ]; then
  fail "Telegram token file not readable: $TELEGRAM_TOKEN_FILE"
fi

if [ "$PRINT_SUMMARY_ONLY" -eq 1 ]; then
  cat <<EOF
repo_dir=$REPO_DIR
data_dir=$DATA_DIR
branch=$BRANCH
mode=$MODE
launchd=$INSTALL_LAUNCHD
fresh_db=$FRESH_DB
migrate_db=${MIGRATE_DB_PATH:-}
skip_openclaw_wizard=$SKIP_OPENCLAW_WIZARD
telegram_token_file=${TELEGRAM_TOKEN_FILE:-}
repo_slug=$REPO_SLUG
EOF
  exit 0
fi

ensure_github_cli
ensure_github_auth
need_cmd git
mkdir -p "$(dirname "$REPO_DIR")" "$DATA_DIR"

if [ ! -d "$REPO_DIR/.git" ]; then
  say "Cloning $REPO_SLUG into $REPO_DIR"
  if [ -n "$BRANCH" ]; then
    gh repo clone "$REPO_SLUG" "$REPO_DIR" -- --branch "$BRANCH"
  else
    gh repo clone "$REPO_SLUG" "$REPO_DIR"
  fi
else
  say "Repo already exists at $REPO_DIR"
fi

cd "$REPO_DIR"

INSTALL_ARGS=(--repo-dir "$REPO_DIR" --data-dir "$DATA_DIR" --branch "$BRANCH")
if [ "$MODE" = "dev" ]; then
  INSTALL_ARGS+=(--dev)
fi
if [ "$INSTALL_LAUNCHD" -eq 1 ]; then
  INSTALL_ARGS+=(--launchd)
fi
if [ "$FRESH_DB" -eq 1 ]; then
  INSTALL_ARGS+=(--fresh-db)
fi
if [ -n "$MIGRATE_DB_PATH" ]; then
  INSTALL_ARGS+=(--migrate-db "$MIGRATE_DB_PATH")
fi
if [ "$SKIP_OPENCLAW_WIZARD" -eq 1 ]; then
  INSTALL_ARGS+=(--skip-openclaw-wizard)
fi
if [ -n "$TELEGRAM_TOKEN_FILE" ]; then
  INSTALL_ARGS+=(--telegram-token-file "$TELEGRAM_TOKEN_FILE")
fi

exec ./scripts/install.sh "${INSTALL_ARGS[@]}"
