#!/usr/bin/env bash
# Последовательные проверки этапов на 4 и 6 баллов.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PROJECT="hw3-basics-$(date +%s)-$$"
SINGLE="$PROJECT-single"
STAGE="проверка инструментов"
TMP=$(mktemp -d)
export APP_PORT=0 GREETING='Hello from Ilya!'
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES
compose() {
    docker compose --env-file /dev/null -p "$PROJECT" -f "$ROOT/compose.sqlite.yaml" "$@"
}
cleanup() {
    local code=$?
    trap - EXIT
    set +e
    if [ "$code" -ne 0 ]; then
        printf 'FAIL: %s\n' "$STAGE" >&2
        docker logs "$SINGLE" >&2
        compose logs --no-color >&2
    fi
    docker rm -f "$SINGLE" >/dev/null 2>&1
    compose down -v --timeout 30
    local cleanup_code=$?
    rm -rf "$TMP"
    if [ "$code" -eq 0 ]; then code=$cleanup_code; fi
    if [ "$code" -eq 0 ]; then printf '\nPASS: этапы 4 и 6 проверены.\n'; fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ready() {
    local deadline=$((SECONDS + 90))
    until curl -fsS --connect-timeout 2 --max-time 3 "$URL/readyz" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1
    done
}
check() {
    local method=$1 endpoint=$2 expected=$3
    curl -fsS --connect-timeout 2 --max-time 5 -X "$method" "$URL$endpoint" > "$TMP/response.json"
    printf '%s %s: ' "$method" "$endpoint"
    cat "$TMP/response.json"
    printf '\n'
    docker exec -i "$ID" python -c \
        'import json,sys; d=json.load(sys.stdin); assert d["count"]==int(sys.argv[1]), d; assert d["greeting"]=="Hello from Ilya!", d' \
        "$expected" < "$TMP/response.json"
}
docker info >/dev/null
command -v curl >/dev/null

STAGE='4 балла: один контейнер'
printf '\n=== %s ===\n' "$STAGE"
docker build -t hw3-counter .
ID=$(docker run -d --name "$SINGLE" -p 127.0.0.1:0:8000 -e GREETING="$GREETING" hw3-counter)
MAPPING=$(docker port "$ID" 8000/tcp)
URL="http://127.0.0.1:${MAPPING##*:}"
ready
check GET / 0
check POST /increment 1
check POST /increment 2
docker logs "$ID"
docker rm -f "$ID"

STAGE='6 баллов: Compose и SQLite volume'
printf '\n=== %s ===\n' "$STAGE"
compose up -d --build --wait --wait-timeout 90
ID=$(compose ps -q app)
MAPPING=$(compose port app 8000)
URL="http://127.0.0.1:${MAPPING##*:}"
check GET / 0
check POST /increment 1
check POST /increment 2
compose logs --no-color
compose down --timeout 30
compose up -d --wait --wait-timeout 90
ID=$(compose ps -q app)
MAPPING=$(compose port app 8000)
URL="http://127.0.0.1:${MAPPING##*:}"
check GET / 2
compose logs --no-color
