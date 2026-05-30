#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    B=$(tput bold); R=$(tput sgr0)
    RED=$(tput setaf 1); GRN=$(tput setaf 2); YLW=$(tput setaf 3); BLU=$(tput setaf 4)
else
    B=""; R=""; RED=""; GRN=""; YLW=""; BLU=""
fi

say()   { echo "${B}${BLU}== $*${R}"; }
ok()    { echo "${GRN}ok${R}   $*"; }
warn()  { echo "${YLW}warn${R} $*"; }
die()   { echo "${RED}err${R}  $*" >&2; exit 1; }
hint()  { echo "     $*"; }

ask() {
    local q="$1" def="${2:-y}" h r
    [[ "$def" == "y" ]] && h="[Y/n]" || h="[y/N]"
    read -r -p "$q $h " r
    r="${r:-$def}"
    [[ "$r" =~ ^[Yy]$ ]]
}

gen_hex()  {
    command -v openssl &>/dev/null \
        && openssl rand -hex 32 \
        || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

gen_pw() {
    command -v openssl &>/dev/null \
        && openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 \
        || head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24
}

port_busy() {
    local p="$1"
    if command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"
    elif command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"
    else
        return 1
    fi
}

say "docker"

command -v docker &>/dev/null || {
    die "docker not found. install it from https://docs.docker.com/engine/install/ and re-run."
}
ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"

docker compose version &>/dev/null || die "docker compose plugin missing. update docker or install the plugin."
ok "compose $(docker compose version --short)"

docker info &>/dev/null || {
    hint "daemon not reachable. on linux: sudo systemctl start docker, or add yourself to the docker group."
    hint "on macos: open docker desktop and wait until it says running."
    die "docker daemon not running"
}
ok "daemon up"

say "config"

[[ -f .env.example ]] || die ".env.example missing. run this from the EFMS-deploy directory."

write_env=true
if [[ -f .env ]]; then
    if ask "existing .env found, keep it?" y; then
        write_env=false
        ok "keeping existing .env"
    else
        warn "existing .env will be overwritten"
    fi
fi

if $write_env; then
    DB_USER=efms
    DB_NAME=efms_db

    if ask "generate a random jwt secret?" y; then
        JWT_SECRET=$(gen_hex)
        ok "generated (64 chars)"
    else
        while :; do
            read -r -s -p "jwt secret (32+ chars): " JWT_SECRET; echo
            (( ${#JWT_SECRET} >= 32 )) && { ok "accepted (${#JWT_SECRET} chars)"; break; }
            warn "need at least 32 chars"
        done
    fi

    if ask "generate a random db password?" y; then
        DB_PASS=$(gen_pw)
        ok "generated (24 chars)"
    else
        while :; do
            read -r -s -p "db password (8+ chars): " DB_PASS; echo
            (( ${#DB_PASS} >= 8 )) && { ok "accepted"; break; }
            warn "need at least 8 chars"
        done
    fi

    read -r -p "api url for the browser [http://localhost:8080]: " API_URL
    API_URL="${API_URL:-http://localhost:8080}"
    if [[ ! "$API_URL" =~ ^https?:// ]]; then
        API_URL="http://${API_URL}"
        warn "no scheme given, using $API_URL"
    fi

    read -r -p "frontend port [3000]: " FRONTEND_PORT
    FRONTEND_PORT="${FRONTEND_PORT:-3000}"
    port_busy "$FRONTEND_PORT" && warn "port $FRONTEND_PORT looks busy"

    read -r -p "backend port [8080]: " BACKEND_PORT
    BACKEND_PORT="${BACKEND_PORT:-8080}"
    port_busy "$BACKEND_PORT" && warn "port $BACKEND_PORT looks busy"

    cp .env.example .env
    sed -e "s|^DB_USER=.*|DB_USER=$DB_USER|" \
        -e "s|^DB_PASS=.*|DB_PASS=$DB_PASS|" \
        -e "s|^DB_NAME=.*|DB_NAME=$DB_NAME|" \
        -e "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" \
        -e "s|^API_URL=.*|API_URL=$API_URL|" \
        -e "s|^FRONTEND_PORT=.*|FRONTEND_PORT=$FRONTEND_PORT|" \
        -e "s|^BACKEND_PORT=.*|BACKEND_PORT=$BACKEND_PORT|" \
        .env > .env.tmp && mv .env.tmp .env
    chmod 600 .env
    ok "wrote .env from .env.example (600)"
fi

set -a; . .env 2>/dev/null || true; set +a
: "${API_URL:=http://localhost:8080}"
: "${FRONTEND_PORT:=3000}"
: "${BACKEND_PORT:=8080}"
: "${DB_USER:=efms}"
: "${DB_NAME:=efms_db}"
: "${BACKEND_IMAGE:=yonyc/efms-backend}"
: "${FRONTEND_IMAGE:=yonyc/efms-frontend}"
: "${BACKEND_TAG:=latest}"
: "${FRONTEND_TAG:=latest}"

say "summary"
echo "frontend   http://localhost:${FRONTEND_PORT}"
echo "backend    ${API_URL}"
echo "database   ${DB_NAME} as ${DB_USER}, host port 5432"
echo "images     ${BACKEND_IMAGE}:${BACKEND_TAG}"
echo "           ${FRONTEND_IMAGE}:${FRONTEND_TAG}"
echo "           postgis/postgis:15-3.3"
echo

ask "go?" y || { hint "ok, run 'docker compose up -d' yourself when ready."; exit 0; }

say "pull"
docker compose pull || die "pull failed"

say "up"
docker compose up -d || die "compose up failed, check 'docker compose logs'"

say "waiting for services..."
_t0=$(date +%s%3N)
_max=300000
_b=false
_f=false
_lb=1
_tmp=$(mktemp -d)
_bf="$_tmp/b"
_ff="$_tmp/f"

printf "     0.000s / 300.000s\n"

# Background subshell: checks services every 2s, writes a flag file when ready
(
    while true; do
        sleep 2
        [[ ! -f "$_bf" ]] && \
            docker logs efms-backend 2>&1 | grep -q 'Started.*in.*seconds' && \
            touch "$_bf"
        [[ ! -f "$_ff" ]] && \
            curl -s -f "http://localhost:${FRONTEND_PORT}" >/dev/null 2>&1 && \
            touch "$_ff"
        [[ -f "$_bf" && -f "$_ff" ]] && break
    done
) &
_chk=$!

# Display loop: only does cheap flag-file checks, updates every 50ms
while true; do
    _now=$(date +%s%3N)
    _e=$(( _now - _t0 ))
    _s=$(( _e / 1000 ))
    _ms=$(( _e % 1000 ))
    printf "\033[%dA\033[2K\r     %d.%03ds / 300.000s  \033[%dB\r" "$_lb" "$_s" "$_ms" "$_lb"
    [[ $_e -ge $_max ]] && break

    if ! $_b && [[ -f "$_bf" ]]; then
        _b=true
        printf "\033[2K\r"
        ok "backend ready after ${_s}.$(printf '%03d' "$_ms")s"
        _lb=$(( _lb + 1 ))
    fi

    if ! $_f && [[ -f "$_ff" ]]; then
        _f=true
        printf "\033[2K\r"
        ok "frontend ready after ${_s}.$(printf '%03d' "$_ms")s"
        _lb=$(( _lb + 1 ))
    fi

    if $_b && $_f; then break; fi
    sleep 0.05
done

kill "$_chk" 2>/dev/null || true
rm -rf "$_tmp"
echo

[[ "$_b" == "true" ]] || warn "backend did not start within 300s - run: docker compose logs backend"
[[ "$_f" == "true" ]] || warn "frontend did not start within 300s"

say "done"
docker compose ps
echo
echo "open http://localhost:${FRONTEND_PORT}"
echo
echo "logs:   docker compose logs -f"
echo "stop:   docker compose down"
echo "update: docker compose pull && docker compose up -d"
echo "wipe:   docker compose down -v"
