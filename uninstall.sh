#!/bin/bash
# OpenFlux control-plane uninstaller - run as root on the target server:
#   curl -fsSL .../uninstall.sh -o uninstall.sh && sudo bash uninstall.sh
# Removes everything install.sh created: the three systemd services, the
# openflux system user, /opt/openflux, /etc/openflux, the nginx vhost, the
# firewalld port(s) and the exit-node iptables rules.
# Left alone unless asked: system packages (nginx, postgres, snapd, git...),
# Go in /usr/local/go and Let's Encrypt certificates (all shared with other
# software). The Postgres database is dumped to /var/backups before removal.
# Non-interactive use: pre-export answers (REMOVE_DB, REMOVE_LECERT, REMOVE_GO)
# or pass --yes to accept all defaults.
set -Eeuo pipefail

INSTALL_ROOT="/opt/openflux"
ENV_DIR="/etc/openflux"
ENV_FILE="$ENV_DIR/controlplane.env"
NODEAGENT_ENV_FILE="$ENV_DIR/nodeagent.env"
WEB_ENV_FILE="$ENV_DIR/web.env"
NGINX_CONF="/etc/nginx/conf.d/openflux.conf"
SERVICE_NAME="openflux-controlplane"
NODEAGENT_SERVICE_NAME="openflux-nodeagent"
WEB_SERVICE_NAME="openflux-web"
SYSTEM_USER="openflux"
BACKUP_ROOT="/var/backups/openflux-uninstall-$(date +%Y%m%d-%H%M%S)"
INSTALL_LOG="/var/log/openflux-install.log"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'printf "ERROR: uninstall.sh failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help)
            echo "Usage: sudo bash uninstall.sh [-y|--yes]"
            echo "  --yes   accept the default answer to every question (non-interactive)."
            echo "  Env overrides for automation: REMOVE_DB, REMOVE_LECERT, REMOVE_GO (y/n)."
            exit 0
            ;;
        *) die "Unknown argument: $arg (see --help)." ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo bash uninstall.sh)."

# Same prompt mechanics as install.sh: reads from /dev/tty because
# `curl | bash` keeps the script itself on stdin.
if exec 3<>/dev/tty 2>/dev/null; then
    HAVE_TTY=1
    exec 3<&- 3>&-
else
    HAVE_TTY=0
fi

ask() {
    # ask VAR "prompt" "default" - skips the prompt if VAR is already set.
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    if [ "$ASSUME_YES" = "1" ] || [ "$HAVE_TTY" != 1 ]; then
        printf -v "$__var" '%s' "$__default"
        return
    fi
    if [ -n "$__default" ]; then
        printf '%s [%s]: ' "$__prompt" "$__default" > /dev/tty 2>/dev/null || true
    else
        printf '%s: ' "$__prompt" > /dev/tty 2>/dev/null || true
    fi
    read -r __reply < /dev/tty 2>/dev/null || true
    [ -n "$__default" ] && __reply="${__reply:-$__default}"
    printf -v "$__var" '%s' "$__reply"
}

read_env() {
    # read_env VAR file - value from a previous install.sh run, empty if none.
    [ -f "$2" ] || return 0
    grep "^$1=" "$2" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

log "OpenFlux uninstall"
echo "This removes the control-plane, web panel and exit node installed by install.sh."
echo "System packages (nginx, postgres, git...), Go and TLS certificates stay unless you say otherwise."

# Read everything we need from the old config FIRST - the files are deleted below.
PUBLIC_URL="$(read_env CONTROLPLANE_PUBLIC_URL "$ENV_FILE")"
PANEL_PORT="$(printf '%s' "$PUBLIC_URL" | grep -o ':[0-9]*$' | tr -d ':' || true)"
if [ -z "$PANEL_PORT" ]; then
    case "$PUBLIC_URL" in https://*) PANEL_PORT=443 ;; esac
fi
CERT_NAME="$(printf '%s' "$PUBLIC_URL" | sed -e 's#^https\?://##' -e 's#/.*##' -e 's#:.*##')"

ask REMOVE_DB "Remove the Postgres database 'openflux' and role 'openflux'? (dumped to $BACKUP_ROOT first) (y/n)" "y"
REMOVE_LECERT="n"
if [ -n "$CERT_NAME" ] && [ -d "/etc/letsencrypt/live/$CERT_NAME" ]; then
    ask REMOVE_LECERT "Also delete the Let's Encrypt certificate for '$CERT_NAME'? (y/n)" "n"
fi
REMOVE_GO="n"
if [ -x /usr/local/go/bin/go ]; then
    ask REMOVE_GO "Also remove Go from /usr/local/go ($(/usr/local/go/bin/go version 2>/dev/null || echo unknown))? (y/n)" "n"
fi

log "Stopping and removing systemd services"
for svc in "$SERVICE_NAME" "$WEB_SERVICE_NAME" "$NODEAGENT_SERVICE_NAME"; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    systemctl reset-failed "$svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$svc.service"
    rm -rf "/etc/systemd/system/$svc.service.d"
done
systemctl daemon-reload >/dev/null 2>&1 || true

log "Removing exit-node iptables rules"
iptables -D OUTPUT -p tcp --tcp-flags RST RST -m mark ! --mark 0x2547 -j DROP 2>/dev/null || true
iptables -D OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
iptables -D OUTPUT -p icmp --icmp-type port-unreachable -j DROP 2>/dev/null || true

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    log "Removing firewalld port(s)"
    # Only a non-standard panel port was added solely for us; 80/443 are
    # routinely shared with other services, so those are left untouched.
    if [ -n "$PANEL_PORT" ] && [ "$PANEL_PORT" != "80" ] && [ "$PANEL_PORT" != "443" ]; then
        firewall-cmd --permanent --remove-port="$PANEL_PORT/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        warn "Port ${PANEL_PORT:-443}/tcp left in firewalld (shared standard port) - remove by hand if nothing else needs it."
    fi
fi

if [ -f "$NGINX_CONF" ]; then
    log "Removing the nginx vhost"
    rm -f "$NGINX_CONF"
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        else
            warn "nginx -t fails after removing the vhost - check the remaining config by hand."
        fi
    fi
fi

if [ "$REMOVE_DB" = "y" ] || [ "$REMOVE_DB" = "Y" ]; then
    if command -v psql >/dev/null 2>&1 && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='openflux'" 2>/dev/null | grep -q 1; then
        log "Backing up and dropping the Postgres database"
        mkdir -p "$BACKUP_ROOT"
        if sudo -u postgres pg_dump openflux > "$BACKUP_ROOT/openflux.sql" 2>/dev/null; then
            log "Database dumped to $BACKUP_ROOT/openflux.sql"
        else
            warn "Database backup failed - dropping anyway as requested."
        fi
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS openflux;" >/dev/null 2>&1 ||
            warn "Could not drop database openflux."
        sudo -u postgres psql -c "DROP ROLE IF EXISTS openflux;" >/dev/null 2>&1 ||
            warn "Could not drop role openflux (it may still own objects elsewhere)."
    else
        log "No openflux Postgres database found - nothing to drop"
    fi
else
    log "Keeping the Postgres database and role as requested"
fi

if [ "$REMOVE_LECERT" = "y" ] || [ "$REMOVE_LECERT" = "Y" ]; then
    log "Deleting the Let's Encrypt certificate for '$CERT_NAME'"
    certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 ||
        warn "certbot could not delete the certificate - check: certbot certificates"
fi

if [ "$REMOVE_GO" = "y" ] || [ "$REMOVE_GO" = "Y" ]; then
    log "Removing Go from /usr/local/go"
    rm -rf /usr/local/go
fi

log "Removing files and the system user"
rm -rf "$INSTALL_ROOT" "$ENV_DIR"
rmdir /var/www/certbot 2>/dev/null || true
if command -v git >/dev/null 2>&1; then
    git config --global --unset-all safe.directory "$INSTALL_ROOT/server" 2>/dev/null || true
fi
if id -u "$SYSTEM_USER" >/dev/null 2>&1; then
    userdel "$SYSTEM_USER" 2>/dev/null || warn "Could not delete user $SYSTEM_USER."
fi
rm -f "$INSTALL_LOG"

log "Done"
cat <<SUMMARY

  Removed: services ($SERVICE_NAME, $WEB_SERVICE_NAME, $NODEAGENT_SERVICE_NAME),
           $SYSTEM_USER user, $INSTALL_ROOT, $ENV_DIR, nginx vhost.
SUMMARY
if [ "$REMOVE_DB" = "y" ] || [ "$REMOVE_DB" = "Y" ]; then
    echo "  Database backup (if one existed): $BACKUP_ROOT/openflux.sql"
fi
cat <<SUMMARY
  Left in place: system packages (nginx, postgres, git...), Go ($([ "$REMOVE_GO" = "y" ] || [ "$REMOVE_GO" = "Y" ] && echo removed || echo kept)),
           TLS certificates ($([ "$REMOVE_LECERT" = "y" ] || [ "$REMOVE_LECERT" = "Y" ] && echo removed || echo kept)).
  Note: install.sh deleted nginx's stock default vhosts - those are not restored.
  Reinstall any time with install.sh.

SUMMARY
