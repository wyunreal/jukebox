#!/usr/bin/env bash
#
# jukebox-menu-font.sh - make moOde's menus follow the native Font size setting
#                       and let them be scaled a bit larger than the page body.
#
# The problem
# -----------
# moOde scales the UI with a CSS variable, --pbfont, which the Preferences ->
# Font size setting writes on <body>. But --pbfont is applied by ONE rule:
#
#   #content { font-size: var(--pbfont); }
#
# Everything inside #content grows; the menus do not, because they live
# OUTSIDE #content:
#   * #context-menus      (the ⋯ playback context menu, queue/db menus)
#   * #panel-header       (the "m" dashboard menu)
#   * #viewswitch         (the Library dropdown; this one is *inside* #content
#                          but its buttons carry a fixed 1em/1.15em size)
# They are sized by hard-coded rules (.dropdown-menu > li > a {font-size:1em}
# plus a media query that bumps it to 1.15em at 800x480).
#
# The fix
# -------
# Append one small block at the end of the served stylesheet that re-points the
# menu selectors at var(--pbfont), with a multiplier so the menus can be a bit
# bigger than the body text. Cascade order makes it win; `!important` is used
# so the media-query rules cannot override it.
#
# Because it uses var(--pbfont), the menus now FOLLOW the Font size setting:
# Large / Larger / X-Large scale the menus too (with the multiplier on top).
#
# moOde regenerates styles.min.css on updates (owned by the moode-player
# package), so a systemd path unit re-applies this block when the file changes.
#
# Commands:
#   sudo ./jukebox-menu-font.sh install [--scale 1.35]
#   sudo ./jukebox-menu-font.sh verify
#   sudo ./jukebox-menu-font.sh apply        # re-assert (used by the guard)
#   sudo ./jukebox-menu-font.sh status
#   sudo ./jukebox-menu-font.sh uninstall
#
set -euo pipefail

VERSION="1.0.0"

APPLY_DIR="/usr/local/jukebox-menu-font"
CONFIG_ENV="$APPLY_DIR/config.env"
LOG_FILE="/var/log/jukebox-menu-font.log"
CSS_FILE="/var/www/css/styles.min.css"
CSS_BAK="$APPLY_DIR/styles.min.css.orig"
GUARD_SERVICE="/etc/systemd/system/jukebox-menu-font-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-menu-font-guard.path"

BEGIN_MARK="/* jukebox-menus begin */"
END_MARK="/* jukebox-menus end */"

# How much bigger the menus are than the page body (1.0 = same as --pbfont).
SCALE="${JB_MENU_SCALE:-1.35}"

# ------------------------------------------------------------------- helpers

log()  { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

load_config_env() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
    SCALE="${JB_MENU_SCALE:-1.35}"
  fi
}

write_config_env() {
  mkdir -p "$APPLY_DIR"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-menu-font settings (edit with care; rerun install to regenerate)
JB_MENU_SCALE=$SCALE
EOF
  chmod 0644 "$CONFIG_ENV"
}

# --------------------------------------------------------------- CSS editing

# Remove any previous jukebox block from the stylesheet (idempotent).
strip_block() {
  python3 - "$CSS_FILE" "$BEGIN_MARK" "$END_MARK" <<'PY'
import re, sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    css = open(path).read()
except OSError:
    sys.exit(0)
css = re.sub(r'\n?' + re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '\n', css, flags=re.S)
open(path, 'w').write(css)
PY
}

render_block() {
  cat <<EOF

$BEGIN_MARK
/* Managed by jukebox-menu-font: make menus follow the native Font size
   setting (--pbfont) and scale them by $SCALE. Menus only; the rest of the UI
   is untouched. Re-applied by jukebox-menu-font-guard.path. */
.dropdown-menu>li>a,
#context-menus .dropdown-menu>li>a,
#panel-header .dropdown-menu>li>a,
.viewswitch .btn:not(#viewswitch-search),
#dashboard-menu .dropdown-menu>li>a {
  font-size: calc(var(--pbfont, 12px) * $SCALE) !important;
  line-height: 2.35em !important;
  padding-top: .3em !important;
  padding-bottom: .3em !important;
}
#panel-header .dropdown-menu,
.viewswitch .dropdown-menu {min-width: 16rem;}
$END_MARK
EOF
}

apply_css() {
  [ -f "$CSS_FILE" ] || die "$CSS_FILE not found (is moOde installed?)"
  # Keep a pristine copy the first time we ever touch the file.
  if [ ! -f "$CSS_BAK" ]; then
    mkdir -p "$APPLY_DIR"
    cp -a "$CSS_FILE" "$CSS_BAK"
  fi
  strip_block
  render_block >>"$CSS_FILE"
  log "applied menu font block (scale=$SCALE)"
}

# ------------------------------------------------------------------- install

install_units() {
  cat >"$GUARD_SERVICE" <<EOF
[Unit]
Description=Jukebox menu font guard (re-assert menu CSS)
After=nginx.service

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=$APPLY_DIR/jukebox-menu-font.sh apply

[Install]
WantedBy=multi-user.target
EOF
  cat >"$GUARD_PATH" <<EOF
[Unit]
Description=Watch moOde stylesheet for menu font changes

[Path]
PathChanged=$CSS_FILE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable jukebox-menu-font-guard.service >/dev/null 2>&1 || true
  systemctl enable --now jukebox-menu-font-guard.path >/dev/null 2>&1 || true
}

remove_units() {
  systemctl disable --now jukebox-menu-font-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-menu-font-guard.service >/dev/null 2>&1 || true
  rm -f "$GUARD_PATH" "$GUARD_SERVICE"
  systemctl daemon-reload
}

restart_kiosk() {
  # The local display caches the stylesheet; a reboot also picks it up.
  systemctl restart localdisplay.service >/dev/null 2>&1 || true
}

cmd_install() {
  require_root
  say "Installing jukebox menu font (v$VERSION)"
  mkdir -p "$APPLY_DIR"
  install -m 0755 "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$APPLY_DIR/$(basename "$0")" 2>/dev/null || true
  write_config_env
  apply_css
  install_units
  restart_kiosk
  ok "installed (menus now follow Font size, scaled x$SCALE)"
  cmd_verify || true
  say "Done"
  cat <<EOF
    * Menus (context, "m" dashboard, Library) scale with an extra x$SCALE.
    * They follow the native Preferences -> Font size setting (--pbfont).
    * The guard re-applies the block if moOde rewrites styles.min.css.
    * Revert: sudo $0 uninstall
EOF
}

cmd_apply() {
  require_root
  [ -d "$APPLY_DIR" ] || { log "apply: not installed"; exit 0; }
  load_config_env
  apply_css
}

cmd_verify() {
  local rc=0 n
  say "Verification"
  if grep -qF "$BEGIN_MARK" "$CSS_FILE" 2>/dev/null; then
    ok "menu font block present in $CSS_FILE"
  else
    fail "menu font block missing"; rc=$((rc+1))
  fi
  if grep -qF 'var(--pbfont' "$CSS_FILE" 2>/dev/null; then
    ok "menus use the native Font size variable (--pbfont)"
  else
    fail "menus are not using --pbfont"; rc=$((rc+1))
  fi
  n="$(grep -cF 'dropdown-menu>li>a' "$CSS_FILE" 2>/dev/null || true)"
  if [ "${n:-0}" -gt 0 ]; then
    ok "dropdown selectors present ($n rules)"
  else
    fail "dropdown selectors not found (wrong stylesheet?)"; rc=$((rc+1))
  fi
  if systemctl is-active --quiet jukebox-menu-font-guard.path; then
    ok "guard path unit active"
  else
    warn "guard path unit not active"
  fi
  [ $rc -eq 0 ] && say "All checks passed" || say "Checks failed: $rc"
  return $rc
}

cmd_status() {
  say "jukebox-menu-font status"
  echo "    installed : $([ -d "$APPLY_DIR" ] && echo yes || echo no)"
  [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" && echo "    scale     : ${JB_MENU_SCALE:-?}"
  if grep -qF "$BEGIN_MARK" "$CSS_FILE" 2>/dev/null; then
    echo "    css block : present"
  else
    echo "    css block : missing"
  fi
  echo "    guard     : $(systemctl is-active jukebox-menu-font-guard.path 2>/dev/null || echo -)"
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox menu font"
  remove_units
  # Restore the pristine stylesheet if we kept a copy.
  if [ -f "$CSS_BAK" ]; then
    cp -a "$CSS_BAK" "$CSS_FILE"
    ok "stylesheet restored from $CSS_BAK"
  else
    strip_block
    ok "menu block removed"
  fi
  restart_kiosk
  rm -rf "$APPLY_DIR"
  ok "uninstalled (reboot recommended)"
}

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scale) SCALE="$2"; shift 2 ;;
      --scale=*) SCALE="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      install|verify|apply|status|uninstall) mode="$1"; shift ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  case "$mode" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    apply)     cmd_apply ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
