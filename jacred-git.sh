#!/usr/bin/env bash
#
# jacred-git.sh — сборка JacRed из исходников вашего форка и деплой в /opt/jacred.
# Отличие от jacred.sh: тянет код из git (форк), собирает make publish и обновляет
# установку, не трогая Data/. Подходит для кастомных изменений поверх апстрима.
#
# Использование: sudo bash jacred-git.sh
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SRC_DIR="/opt/jacred-src"
readonly INSTALL_ROOT="/opt/jacred"
readonly JACRED_USER="jacred"
readonly SERVICE_NAME="jacred"

FORK_REPO="${FORK_REPO:-https://github.com/GamesIS/jacred.git}"
FORK_BRANCH="${FORK_BRANCH:-feature/min-seeds-peers}"
INSTALL_DEPS=1
MAKE_BACKUP=1

log_info() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
log_err() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Собирает последнюю версию вашего форка JacRed из исходников и обновляет /opt/jacred.
Требуется установка jacred.sh (systemd-сервис + /opt/jacred).

Options:
  --repo URL       URL форка (default: $FORK_REPO)
  --branch NAME    Ветка форка (default: $FORK_BRANCH)
  --skip-deps      Не устанавливать зависимости (git/make/node/dotnet)
  --no-backup      Не создавать резервную копию ${INSTALL_ROOT}.bak при первом деплое
  -h, --help       Show this help and exit

Examples:
  sudo $SCRIPT_NAME
  sudo $SCRIPT_NAME --branch main
  FORK_REPO=https://github.com/user/jacred.git sudo $SCRIPT_NAME
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

detect_rid() {
  case "$(uname -m)" in
    x86_64)   echo "linux-x64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *)
      log_err "Неподдерживаемая архитектура: $(uname -m)"
      exit 1
      ;;
  esac
}

ensure_deps() {
  if [[ "$INSTALL_DEPS" -ne 1 ]]; then
    log_info "Пропускаю установку зависимостей (--skip-deps)"
    return 0
  fi

  local need_apt=0 cmd
  for cmd in git make curl rsync unzip; do
    command -v "$cmd" >/dev/null 2>&1 || need_apt=1
  done
  if [[ "$need_apt" -eq 1 ]]; then
    log_info "Устанавливаю системные пакеты (git, make, curl, rsync, unzip)..."
    apt update
    apt install -y --no-install-recommends git make curl rsync unzip
  fi

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)" -lt 22 ]]; then
    log_info "Устанавливаю Node.js 22 (nodesource)..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y nodejs
  fi

  if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    log_info "Устанавливаю .NET 10 SDK..."
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp/dotnet-install.sh"
    chmod +x "$tmp/dotnet-install.sh"
    "$tmp/dotnet-install.sh" --channel 10.0 --install-dir /usr/share/dotnet
    ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
    rm -rf "$tmp"
  fi
}

ensure_src() {
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log_info "Клонирую форк $FORK_REPO (ветка $FORK_BRANCH)..."
    git clone --branch "$FORK_BRANCH" "$FORK_REPO" "$SRC_DIR"
    return 0
  fi

  log_info "Обновляю исходники из $FORK_REPO:$FORK_BRANCH..."
  cd "$SRC_DIR"
  git fetch --tags --prune origin
  git checkout "$FORK_BRANCH" 2>/dev/null || git checkout -b "$FORK_BRANCH" "origin/$FORK_BRANCH"
  git reset --hard "origin/$FORK_BRANCH"
}

build() {
  log_info "Собираю (make publish, это займёт несколько минут)..."
  cd "$SRC_DIR"
  make publish
}

deploy() {
  local rid="$1"
  local build_dir="$SRC_DIR/dist/$rid"

  if [[ ! -d "$INSTALL_ROOT" ]]; then
    log_err "Каталог установки $INSTALL_ROOT не найден. Сначала установите JacRed:"
    log_err "  curl -s https://raw.githubusercontent.com/jacred-fdb/jacred/main/jacred.sh | bash"
    exit 1
  fi

  if [[ ! -f "$build_dir/JacRed" ]]; then
    log_err "Бинарник не найден: $build_dir/JacRed"
    exit 1
  fi

  if [[ "$MAKE_BACKUP" -eq 1 && ! -d "${INSTALL_ROOT}.bak" ]]; then
    log_info "Первый деплой: создаю резервную копию ${INSTALL_ROOT}.bak"
    cp -a "$INSTALL_ROOT" "${INSTALL_ROOT}.bak"
  fi

  log_info "Останавливаю сервис $SERVICE_NAME..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  log_info "Копирую сборку в $INSTALL_ROOT (Data/ и init.yaml сохраняются)..."
  rsync -a "$build_dir/" "$INSTALL_ROOT/"
  chown -R "${JACRED_USER}:${JACRED_USER}" "$INSTALL_ROOT"

  log_info "Запускаю сервис $SERVICE_NAME..."
  systemctl start "$SERVICE_NAME"

  sleep 5
  if curl -fsS "http://127.0.0.1:9117/health" >/dev/null 2>&1; then
    log_info "Health check: OK"
  else
    log_info "Сервис запущен; health будет готов после загрузки БД (~10-30 с)"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --repo)
        FORK_REPO="$2"
        shift 2
        ;;
      --branch)
        FORK_BRANCH="$2"
        shift 2
        ;;
      --skip-deps)
        INSTALL_DEPS=0
        shift
        ;;
      --no-backup)
        MAKE_BACKUP=0
        shift
        ;;
      *)
        log_err "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  require_root "$@"
  parse_args "$@"

  if [[ "$(uname -s)" != "Linux" ]]; then
    log_err "Скрипт поддерживает только Linux."
    exit 1
  fi

  ensure_deps
  ensure_src
  build
  deploy "$(detect_rid)"

  log_info "Готово. Версия: $(cd "$SRC_DIR" && git describe --tags --always 2>/dev/null || echo unknown)"
  log_info "Для обновления просто запустите снова: sudo bash $0"
}

main "$@"
