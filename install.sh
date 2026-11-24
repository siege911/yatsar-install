#!/usr/bin/env bash
# Install one Yatsar unit on a new Linux server (R398). Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/siege911/yatsar-install/main/install.sh | sudo bash
#   sudo bash install.sh                      a Client Platform or an MSP Hub (it asks which)
#   sudo bash install.sh --edition yatsar     the one Yatsar Hub (never offered in the menu)
#
# It asks for the edition, this server's hostnames, the break-glass Admin password, the Hub
# this unit reports to, and the registry token. Everything else it generates. It then pulls the
# release image, takes the unit's files from that image, and starts the unit. Update later
# with one command: `yatsar update`.
#
# Unattended: set YATSAR_EDITION, YATSAR_PUBLIC_HOSTNAME, YATSAR_APP_HOSTNAME,
# YATSAR_BOOTSTRAP_ADMIN_PASSWORD, YATSAR_HUB_URL, YATSAR_REGISTRY_TOKEN and
# YATSAR_RELEASE_PUBLIC_KEY in the environment; a value that is set is not asked for.
set -euo pipefail

# Defaults for this product. The release build stamps the public key when it publishes this file.
REGISTRY=${YATSAR_REGISTRY:-ghcr.io/siege911/yatsar}
REGISTRY_USER=${YATSAR_REGISTRY_USER:-siege911}
TAG=${YATSAR_VERSION:-stable}
DEFAULT_HUB_URL=https://hub.yatsar.app
RELEASE_PUBLIC_KEY=${YATSAR_RELEASE_PUBLIC_KEY:-nrErUQxhVHdAgQ+RMJdZq5VnYYxondOTjQ0p2Ptunrk=}

UNIT=/srv/yatsar
VENV=/opt/yatsar-updater
SIGNER_DIR=/etc/yatsar-signer
EDITION=${YATSAR_EDITION:-}

say() { printf '%s\n' "$*"; }
die() { printf '\ninstall: %s\n' "$*" >&2; exit 1; }
# Questions read the terminal, so they work when this script itself arrives on stdin.
ask() {  # ask <variable> <question> [default]
  local answer=""
  read -r -p "$2${3:+ [$3]}: " answer </dev/tty || die "no terminal to ask on; set the YATSAR_* variables instead"
  printf -v "$1" '%s' "${answer:-${3:-}}"
}
ask_secret() {  # ask_secret <variable> <question>
  local answer=""
  read -r -s -p "$2: " answer </dev/tty || die "no terminal to ask on; set the YATSAR_* variables instead"
  printf '\n' >/dev/tty
  printf -v "$1" '%s' "$answer"
}
hostname_ok() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --edition) EDITION=${2:-}; shift 2 ;;
    --version) TAG=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run this as root (sudo bash install.sh)"
[ "$(uname -s)" = Linux ] || die "a Yatsar unit runs on a Linux server"
[ ! -e "$UNIT/.env" ] || die "a unit is already installed in $UNIT. To update it, run: yatsar update"

say "Yatsar install"
say ""

# 1. What this server is. The Yatsar Hub is one of a kind: only the explicit flag installs it.
if [ -z "$EDITION" ]; then
  say "What is this server?"
  say "  1) Client Platform (default)"
  say "  2) MSP Hub"
  ask choice "Choose 1 or 2" 1
  case "$choice" in 1) EDITION=platform ;; 2) EDITION=msp ;; *) die "choose 1 or 2" ;; esac
fi
case "$EDITION" in
  platform) KIND="Client Platform" ;;
  msp) KIND="MSP Hub" ;;
  yatsar) KIND="Yatsar Hub" ;;
  *) die "--edition is platform, msp or yatsar" ;;
esac
say "Installing: $KIND"

# 2. Its address. Caddy asks Let's Encrypt for both names, so DNS must point here first.
HOST=${YATSAR_PUBLIC_HOSTNAME:-}
[ -n "$HOST" ] || ask HOST "This server's public hostname (for example yatsar.example.org)"
hostname_ok "$HOST" || die "'$HOST' is not a hostname"
APP_HOST=${YATSAR_APP_HOSTNAME:-}
[ -n "$APP_HOST" ] || ask APP_HOST "Hostname for Apps (a second name for this server)" "apps.$HOST"
hostname_ok "$APP_HOST" && [ "$APP_HOST" != "$HOST" ] || die "the Apps hostname must be a different hostname"

# 3. The break-glass Admin: the local account that signs in when nothing else can.
PASSWORD=${YATSAR_BOOTSTRAP_ADMIN_PASSWORD:-}
while [ -z "$PASSWORD" ]; do
  ask_secret first "Password for the break-glass Admin account (12 characters or more)"
  ask_secret second "The same password again"
  if [ "$first" != "$second" ]; then say "The two did not match."
  elif [ ${#first} -lt 12 ]; then say "Use 12 characters or more."
  elif [[ "$first" == *"'"* ]]; then say "Leave out the single quote character (')."
  else PASSWORD=$first; fi
done
[ ${#PASSWORD} -ge 12 ] && [[ "$PASSWORD" != *"'"* ]] || die "the password needs 12 characters and no single quote"

# 4. The Hub it reports to. The Yatsar Hub has none.
HUB_URL=""
if [ "$EDITION" != yatsar ]; then
  HUB_URL=${YATSAR_HUB_URL:-}
  [ -n "$HUB_URL" ] || ask HUB_URL "Hub URL" "$DEFAULT_HUB_URL"
  [[ "$HUB_URL" =~ ^https://[^/[:space:]]+$ ]] || die "the Hub URL looks like https://hub.example.org"
  [ -n "$RELEASE_PUBLIC_KEY" ] || ask RELEASE_PUBLIC_KEY "Release public key (from the Yatsar Hub's install summary)"
  [ -n "$RELEASE_PUBLIC_KEY" ] || die "updates are verified with the release public key; it is required"
fi

# 5. The registry the images come from.
TOKEN=${YATSAR_REGISTRY_TOKEN:-}
[ -n "$TOKEN" ] || ask_secret TOKEN "Registry token (read-only, for ${REGISTRY%%/*})"
[ -n "$TOKEN" ] || die "the registry token is required"

say ""
say "Preparing this server…"
if ! command -v docker >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die "install Docker Engine with Compose v2 first, then run this again"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose version)"
if ! python3 -c 'import sys, venv, ensurepip; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
  command -v apt-get >/dev/null 2>&1 || die "install Python 3.12 or newer with its venv module first"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv >/dev/null
  python3 -c 'import sys, venv, ensurepip; sys.exit(sys.version_info < (3, 12))' \
    || die "this server's Python is older than 3.12. Use Ubuntu 24.04 or Debian 13, or newer"
fi
getent hosts "$HOST" >/dev/null || say "Note: $HOST does not resolve yet. HTTPS starts working once DNS points here."

# The image, by digest: a tag only chooses which release to start from.
printf '%s' "$TOKEN" | docker login "${REGISTRY%%/*}" --username "$REGISTRY_USER" --password-stdin >/dev/null \
  || die "the registry refused that token"
REPOSITORY="$REGISTRY/$EDITION"
say "Pulling ${REPOSITORY}:${TAG}…"
docker pull --quiet "$REPOSITORY:$TAG" >/dev/null || die "could not pull $REPOSITORY:$TAG"
IMAGE=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REPOSITORY:$TAG" \
  | grep -F "$REPOSITORY@sha256:" | head -1)
[ -n "$IMAGE" ] || die "the pulled image has no repository digest"
BUILT=$(docker image inspect --format '{{index .Config.Labels "io.yatsar.edition"}}' "$IMAGE")
[ "$BUILT" = "$EDITION" ] || die "that image is built for '$BUILT', not $EDITION"
VERSION=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")

# The unit's own files come from the image, so they always match it (R404).
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
container=$(docker create "$IMAGE")
docker cp "$container:/app/host/." "$WORK/" || die "this image carries no host files; use a newer release"
[ "$EDITION" != yatsar ] || docker cp "$container:/app/release/candidates.json" "$WORK/candidates.json"
docker rm "$container" >/dev/null

umask 077
mkdir -p "$UNIT/data/web" "$UNIT/data/worker" /etc/yatsar /var/lib/yatsar-updater /var/backups/yatsar
chown 10001 "$UNIT/data/web"
chmod 700 "$UNIT/data/web" "$UNIT/data/worker"
for name in docker-compose.yml Caddyfile seccomp-worker.json verify-sandbox.sh yatsar-release-signing.compose.yml; do
  install -m 644 "$WORK/$name" "$UNIT/$name"
done

venv_from() (  # the same steps `yatsar refresh-tools` repeats after every update
  umask 022
  python3 -m venv "$1"
  "$1/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r "$WORK/requirements.runtime.lock"
  "$1/bin/pip" install --quiet --disable-pip-version-check --no-deps "$WORK"/yatsar-*.whl
)
say "Installing the host Updater…"
venv_from "$VENV"

OVERRIDES="[]"
SIGNING=""
if [ "$EDITION" = yatsar ]; then
  # The release signer: its own user, its own key, no network, no Docker (deploy/RELEASES.md).
  getent group yatsar-signing >/dev/null || groupadd --system yatsar-signing
  id yatsar-signer >/dev/null 2>&1 || useradd --system --gid yatsar-signing --shell /usr/sbin/nologin yatsar-signer
  install -d -o root -g yatsar-signing -m 750 "$SIGNER_DIR"
  install -d -o root -g yatsar-signing -m 2770 "$UNIT/release-signing"
  if [ ! -f "$SIGNER_DIR/release.key" ]; then
    say ""
    say "This Hub has no release signing key. Every Platform trusts updates signed with it."
    say "If you are moving an existing Yatsar Hub, stop now and copy its key to $SIGNER_DIR/release.key."
    ask confirm "Type 'new key' to create one for a first Yatsar Hub"
    [ "$confirm" = "new key" ] || die "no key was created. Restore the key, then run this again"
    head -c 32 /dev/urandom > "$SIGNER_DIR/release.key"
  fi
  chown yatsar-signer:yatsar-signing "$SIGNER_DIR/release.key"
  chmod 600 "$SIGNER_DIR/release.key"
  RELEASE_PUBLIC_KEY=$("$VENV/bin/python" - "$SIGNER_DIR/release.key" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read(32))
print(base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode())
PY
)
  install -o root -g yatsar-signing -m 640 "$WORK/candidates.json" "$SIGNER_DIR/candidates.json"
  venv_from /opt/yatsar-signer
  install -m 644 "$WORK/yatsar-release-signer.service" /etc/systemd/system/yatsar-release-signer.service
  OVERRIDES="[\"$UNIT/yatsar-release-signing.compose.yml\"]"
  SIGNING="YATSAR_SIGNING_GID=$(getent group yatsar-signing | cut -d: -f3)"
fi

VAULT_KEY=$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
cat > "$UNIT/.env" <<ENV
# Written by install.sh for a $KIND. Root only. Keep a copy of the secrets somewhere else:
# update backups leave them out on purpose (deploy/UPDATE.md).
YATSAR_PUBLIC_HOSTNAME=$HOST
YATSAR_APP_HOSTNAME=$APP_HOST
YATSAR_APP_ORIGIN=https://$APP_HOST
YATSAR_BOOTSTRAP_ADMIN_PASSWORD='$PASSWORD'
YATSAR_WORKER_TOKEN=$(openssl rand -hex 32)
YATSAR_SECRET_KEY=$(openssl rand -base64 32)
YATSAR_VAULT_KEY=$VAULT_KEY
YATSAR_HUB_URL=$HUB_URL
YATSAR_RELEASE_PUBLIC_KEY=$RELEASE_PUBLIC_KEY
$SIGNING
ENV
printf 'YATSAR_IMAGE=%s\n' "$IMAGE" > "$UNIT/release.env"
cat > /etc/yatsar/updater.json <<JSON
{
  "web_data": "$UNIT/data/web",
  "worker_data": "$UNIT/data/worker",
  "state_dir": "/var/lib/yatsar-updater",
  "backup_dir": "/var/backups/yatsar",
  "repository": "$REPOSITORY",
  "public_key": "$RELEASE_PUBLIC_KEY",
  "public_keys": [],
  "compose_file": "$UNIT/docker-compose.yml",
  "compose_overrides": $OVERRIDES,
  "env_file": "$UNIT/.env",
  "image_file": "$UNIT/release.env",
  "project": "yatsar",
  "health_url": "http://127.0.0.1:8080",
  "docker": "$(command -v docker)",
  "health_timeout": 300,
  "backup_keep": 3,
  "channel": "stable",
  "refused_versions": [],
  "allow_legacy_releases": false,
  "edition": "$EDITION",
  "manage_host_files": true
}
JSON
chmod 600 "$UNIT/.env" "$UNIT/release.env" /etc/yatsar/updater.json
"$VENV/bin/python" -c 'import sys;from yatsar.updater.config import Config;Config.load(sys.argv[1])' /etc/yatsar/updater.json \
  || die "the Updater refused its configuration"
printf '%s\n' "$IMAGE" > "$VENV/.image"
install -m 755 "$WORK/yatsar" /usr/local/bin/yatsar
install -m 644 "$WORK/yatsar-updater.service" /etc/systemd/system/yatsar-updater.service
systemctl daemon-reload
[ "$EDITION" != yatsar ] || systemctl enable --now yatsar-release-signer >/dev/null

say "Starting Yatsar ${VERSION}…"
yatsar restart >/dev/null
ready=""
for _ in $(seq 1 100); do
  if curl -fsS -o /dev/null http://127.0.0.1:8080/api/v1/health/ready 2>/dev/null; then ready=yes; break; fi
  sleep 3
done
[ -n "$ready" ] || die "the unit did not become ready in five minutes. See: yatsar logs web"
systemctl enable --now yatsar-updater >/dev/null
say ""
(cd "$UNIT" && sh verify-sandbox.sh) || say "The sandbox check did not pass. Python Connectors stay off until it does (deploy/SANDBOX.md)."

say ""
say "Yatsar $VERSION is running: https://$HOST"
say "  Sign in as: admin (the break-glass Admin) with the password you chose."
[ "$EDITION" = yatsar ] || say "  Its Hub:    $HUB_URL. Claim this deployment there to license it."
say "  Ports 80 and 443 must be open to the internet, and both hostnames must point here."
say ""
say "Store what follows now, away from this server. It is not shown again."
say "  Vault key (without it, saved Connector Credentials cannot be recovered):"
say "    $VAULT_KEY"
if [ "$EDITION" = yatsar ]; then
  say "  Release public key (every Platform and MSP Hub install asks for it):"
  say "    $RELEASE_PUBLIC_KEY"
  say "  Also back up $SIGNER_DIR/release.key offline. It signs every update."
fi
say ""
say "To update this server later, run:  yatsar update"
