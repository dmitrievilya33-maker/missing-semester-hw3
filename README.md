# ДЗ 3: Docker, счётчик и Redis

Решение содержит этапы на 4, 6, 8 и 10 баллов. Исходники `app/` взяты из
[шаблона](https://github.com/null-ref-exc/hw_3_template/tree/137f87b9774f7b71c123f0e2891f39716d4d8231)
без изменений. [Условие задания](https://github.com/Nikfilk2030/missing_semester_hse_cs/tree/main/2026/amcs/year_1/hw_3).

## Требования и настройки

Нужны работающий Docker с Compose v2 или новее, Bash и curl. Python на компьютере не нужен:
приложение и обработка JSON работают в контейнере.

Все команды выполняются из каталога этого репозитория.

```sh
cp .env.example .env
```

В `.env` можно задать `APP_PORT` (порт на компьютере, по умолчанию 8080)
и `GREETING` (приветствие). Внутренний порт приложения — 8000.
Примеры curl ниже используют стандартный внешний порт 8080.

## 4 балла: один контейнер

```sh
docker build -t hw3-counter .
docker run -d --name hw3-single -p 127.0.0.1:8080:8000 \
  -e GREETING='Hello from Ilya!' hw3-counter
curl -fsS --max-time 5 http://127.0.0.1:8080/readyz
curl -fsS --max-time 5 http://127.0.0.1:8080/
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
docker logs hw3-single
docker rm -f hw3-single
```

После запуска нужно дождаться HTTP 200 у `/readyz` (обычно несколько секунд).
В новом контейнере GET возвращает 0, два POST — 1 и 2.
SQLite находится внутри контейнера; на этом этапе удаление контейнера удаляет данные.

Этапы 4 и 6 также можно проверить последовательно одной командой
`./scripts/check-basics.sh`. Она использует собственный проект и свободный порт,
проверяет ответы и приветствие, печатает логи и удаляет свои тестовые ресурсы.

## 6 баллов: Compose и SQLite volume

```sh
docker compose -p hw3-sqlite -f compose.sqlite.yaml up -d --build --wait --wait-timeout 90
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
curl -fsS --max-time 5 http://127.0.0.1:8080/
docker compose -p hw3-sqlite -f compose.sqlite.yaml down
docker compose -p hw3-sqlite -f compose.sqlite.yaml up -d --wait --wait-timeout 90
curl -fsS --max-time 5 http://127.0.0.1:8080/
docker compose -p hw3-sqlite -f compose.sqlite.yaml logs --no-color
docker compose -p hw3-sqlite -f compose.sqlite.yaml down
```

Значение до и после `down` одинаковое: `/data/counter.db` хранится в именованном
volume `sqlite-data`. Удаление контейнера его не удаляет. Перенос данных из SQLite
в Redis не требуется: следующий этап использует отдельное хранилище.

## 8 баллов: Redis

```sh
docker compose up -d --build --wait --wait-timeout 90
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
curl -fsS --max-time 5 http://127.0.0.1:8080/
# Записать count=N из ответа.
docker compose down
docker compose up -d --wait --wait-timeout 90
curl -fsS --max-time 5 http://127.0.0.1:8080/
# Должен остаться count=N.
docker compose stop redis
curl -sS -i --max-time 5 http://127.0.0.1:8080/healthz
curl -sS -i --max-time 5 http://127.0.0.1:8080/readyz
curl -sS -i --max-time 5 -X POST http://127.0.0.1:8080/increment
# Ожидаются HTTP 200, 503, 503 соответственно.
docker compose start redis
```

Дождаться HTTP 200 у `/readyz`, затем:

```sh
curl -fsS --max-time 5 http://127.0.0.1:8080/
curl -fsS --max-time 5 -X POST http://127.0.0.1:8080/increment
docker compose logs --no-color
```

GET должен вернуть N, следующий POST — N+1. Приложение не перезапускается.
`STORAGE=redis`, адрес хранилища — `redis://redis:6379/0`.
Порт Redis на компьютер не публикуется. Redis хранит AOF в именованном volume
`redis-data`, подключённом к `/data`; `appendfsync always` фиксирует каждую запись.
Healthcheck Redis использует `redis-cli ping`, приложения — `/readyz`.
`depends_on: condition: service_healthy` обеспечивает готовность Redis при старте.
При остановке Redis HTTP-сервер остаётся жив, но healthcheck приложения становится
неуспешным, поскольку хранилище недоступно.

## 10 баллов: ограничения и автоматическая проверка

Приложение работает с UID 10001, корневая файловая система доступна только для чтения.
Лимиты: 256 MiB RAM и 1 CPU. В режиме Redis приложению не требуется запись на диск.
В Dockerfile задан `STOPSIGNAL SIGINT`: приложение штатно закрывает HTTP-сервер
через уже имеющийся обработчик `KeyboardInterrupt`.

```sh
./scripts/check.sh
```

Скрипт создаёт уникальный Compose-проект и использует свободный порт, выбранный Docker.
Проверяет начальный 0, три увеличения, ограничения приложения, пересоздание только
приложения, `down/up`, отключение и восстановление Redis. Далее штатно останавливает
приложение и Redis, сохраняет весь `/data` в `backups/<имя-проекта>.tar`, удаляет
исходный проект с volumes и проверяет восстановление архива в новый volume.
После восстановления счётчик равен 4, следующий POST возвращает 5.

HTTP-запросы ограничены тайм-аутом, ожидание готовности — 90 секундами.
При ошибке выводятся этап и логи, код возврата ненулевой.
Обработчик `trap` удаляет только контейнеры, сеть и volumes своего тестового проекта.
Архив резервной копии остаётся на компьютере; он исключён из Git.
Образы остаются в Docker для повторного использования.

Два запуска подряд с сохранением настоящего вывода:

```bash
mkdir -p reports
set -o pipefail
./scripts/check.sh 2>&1 | tee reports/check-1.log && \
./scripts/check.sh 2>&1 | tee reports/check-2.log
```

См. [отчёт о проверках](REPORT.md). Оба запуска должны завершиться строкой `PASS`.
`down -v` удаляет данные; в ручной проверке сохранности этот флаг использовать нельзя.
Скрипт применяет его только к собственному временному проекту.

## Сдача

В отдельный GitHub-репозиторий нужно включить исходники, Dockerfile, `.dockerignore`,
оба Compose-файла, `.env.example`, README, отчёт, скрипт и логи.
Ссылку отправить в форму из задания. Достаточно одного финального коммита.
