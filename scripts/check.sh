#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
STAGE="проверка инструментов"
PROJECT="hw3-check-$(date +%s)-$$"
HELPER="$PROJECT-copy"
TMP=$(mktemp -d)
BACKUP="$ROOT/backups/$PROJECT.tar"
# 0 просит Docker выбрать свободный порт. Окружение пользователя не влияет на тест.
export APP_PORT=0 GREETING="Recovery check"
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES

compose() {
    docker compose --env-file /dev/null -p "$PROJECT" -f "$ROOT/compose.yaml" "$@"
}

cleanup() {
    local code=$?
    trap - EXIT
    set +e
    if [ "$code" -ne 0 ]; then
        printf '\nFAIL: этап «%s», код %s\n' "$STAGE" "$code" >&2
        compose logs --no-color --tail=80 >&2
    fi
    docker rm -f "$HELPER" >/dev/null 2>&1
    compose down -v --remove-orphans --timeout 30
    local cleanup_code=$?
    rm -rf "$TMP"
    if [ "$code" -eq 0 ] && [ "$cleanup_code" -ne 0 ]; then
        printf 'FAIL: очистка тестового проекта\n' >&2
        code=$cleanup_code
    fi
    if [ "$code" -eq 0 ]; then
        printf '\nPASS: все проверки пройдены; тестовые ресурсы удалены.\n'
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage() { STAGE=$1; printf '\n=== %s ===\n' "$STAGE"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

address() {
    local mapping
    mapping=$(compose port app 8000)
    URL="http://127.0.0.1:${mapping##*:}"
}

request() {
    local method=$1 path=$2 expected=$3 code
    code=$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
        -X "$method" -o "$TMP/response.json" -w '%{http_code}' "$URL$path")
    printf '%s %s -> HTTP %s ' "$method" "$path" "$code"
    cat "$TMP/response.json"
    printf '\n'
    [ "$code" = "$expected" ] || fail "Ожидался HTTP $expected"
}

count_is() {
    local expected=$1 actual
    actual=$(compose exec -T app python -c \
        'import json,sys; print(json.load(sys.stdin)["count"])' < "$TMP/response.json")
    [ "$actual" = "$expected" ] || fail "Ожидался count=$expected, получен $actual"
}

wait_ready() {
    local deadline=$((SECONDS + 90))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -fsS --connect-timeout 2 --max-time 3 "$URL/readyz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail 'Готовность не достигнута за 90 секунд'
}

command -v docker >/dev/null || fail 'Установите и запустите Docker с Compose'
command -v curl >/dev/null || fail 'Не найден curl'
docker info >/dev/null
docker compose version
mkdir -p "$ROOT/backups"
printf 'Тестовый проект: %s\n' "$PROJECT"

stage 'Новое хранилище и N=3 увеличения'
compose up -d --build --wait --wait-timeout 90
address
request GET / 200
count_is 0
for expected in 1 2 3; do
    request POST /increment 200
    count_is "$expected"
done

stage 'Ограничения приложения'
APP_ID=$(compose ps -q app)
compose exec -T app python -c 'import os; uid=os.getuid(); print("uid=", uid); assert uid != 0'
docker inspect "$APP_ID" --format '{{json .HostConfig}}' | \
    compose exec -T app python -c 'import json,sys; c=json.load(sys.stdin); assert c["ReadonlyRootfs"]; assert 0 < c["Memory"] <= 256*1024*1024; assert 0 < c["NanoCpus"] <= 1000000000; print("read_only=true, RAM<=256 MiB, CPU<=1")'

stage 'Пересоздание только приложения'
REDIS_ID=$(compose ps -q redis)
compose up -d --no-deps --force-recreate --wait --wait-timeout 90 app
[ "$(compose ps -q app)" != "$APP_ID" ] || fail 'Приложение не пересоздано'
[ "$(compose ps -q redis)" = "$REDIS_ID" ] || fail 'Redis неожиданно пересоздан'
address
request GET / 200
count_is 3

stage 'Сохранность после down и up без удаления volume'
compose down --timeout 30
compose up -d --wait --wait-timeout 90
address
request GET / 200
count_is 3

stage 'Отключение Redis: 200, 503, 503'
APP_ID=$(compose ps -q app)
APP_STARTED=$(docker inspect --format '{{.State.StartedAt}}' "$APP_ID")
compose stop --timeout 30 redis
request GET /healthz 200
request GET /readyz 503
request POST /increment 503

stage 'Возврат Redis без перезапуска приложения'
compose start redis
wait_ready
[ "$(compose ps -q app)" = "$APP_ID" ] || fail 'Изменился контейнер приложения'
[ "$(docker inspect --format '{{.State.StartedAt}}' "$APP_ID")" = "$APP_STARTED" ] || fail 'Приложение перезапускалось'
request GET / 200
count_is 3
request POST /increment 200
count_is 4

stage 'Согласованная резервная копия остановленного Redis'
compose stop --timeout 30 app
compose stop --timeout 30 redis
REDIS_ID=$(compose ps -a -q redis)
# Архив содержит весь /data, включая каталог AOF, структуру и права.
# stdout двоичный: TTY не используется.
docker run --rm --name "$HELPER" --volumes-from "$REDIS_ID:ro" \
    --entrypoint tar redis:7.4-alpine -C /data -cpf - . > "$BACKUP"
[ -s "$BACKUP" ] || fail 'Пустая резервная копия'
printf 'Резервная копия: %s\n' "$BACKUP"
compose logs --no-color

stage 'Удаление исходного тестового проекта вместе с volumes'
compose down -v --timeout 30

stage 'Восстановление копии в новый volume'
compose create redis
REDIS_ID=$(compose ps -a -q redis)
docker run --rm -i --name "$HELPER" --volumes-from "$REDIS_ID" \
    --entrypoint tar redis:7.4-alpine -C /data -xpf - < "$BACKUP"
compose up -d --wait --wait-timeout 90
address
request GET / 200
count_is 4
request POST /increment 200
count_is 5
stage 'Завершение и очистка'
