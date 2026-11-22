# Отчёт о проверках

Проверки выполнены 22 ноября 2026 года на macOS / Apple Silicon:
Docker Desktop 4.99.0, Engine 29.9.3, Compose 5.7.0.
Все три запуска ниже завершились с кодом 0. Время в логах контейнеров — UTC.

Исходный `app/app.py` соответствует шаблону:
Git blob SHA-1 `85a3e5807ddf81705fdbbfbe4b0d9a896a7a02a6`.

## Команды и полный вывод

```bash
set -o pipefail
./scripts/check-basics.sh 2>&1 | tee reports/basics.log && \
./scripts/check.sh 2>&1 | tee reports/check-1.log && \
./scripts/check.sh 2>&1 | tee reports/check-2.log
```

Точные команды Docker и curl приведены в скриптах и в README.
В логах сохранены сборка, ответы HTTP, вывод приложения и Redis, создание и удаление ресурсов.

| Запуск | Тестовый Compose-проект | Результат | Полный вывод |
| --- | --- | --- | --- |
| Этапы 4 и 6 | `hw3-basics-1795373009-9290` | PASS | [basics.log](reports/basics.log) |
| Полная проверка 1 | `hw3-check-1795373026-9405` | PASS | [check-1.log](reports/check-1.log) |
| Полная проверка 2 | `hw3-check-1795373077-9626` | PASS | [check-2.log](reports/check-2.log) |

## Результаты

| Проверка | Полученный результат |
| --- | --- |
| Один контейнер, SQLite | Приветствие `Hello from Ilya!`, счётчик 0 → 1 → 2 |
| SQLite volume, `down` и `up` | В новом контейнере сохранился count=2 |
| Пустой Redis volume | count=0, три POST дали 1, 2, 3 |
| Ограничения app | UID=10001, read-only rootfs, RAM=256 MiB, CPU=1 |
| Пересоздание только app | Изменился ID app, ID Redis прежний, count=3 |
| `down` и `up` без `-v` | count=3 сохранился |
| `stop redis`, GET /healthz | HTTP 200 |
| `stop redis`, GET /readyz | HTTP 503 |
| `stop redis`, POST /increment | HTTP 503 |
| `start redis` | GET вернул 3, POST вернул 4; ID и время запуска app не изменились |
| Резервное копирование | app и Redis штатно остановлены; весь /data сохранён в tar с правами |
| Удаление исходного проекта | Выполнен `down -v`, исходный volume удалён |
| Восстановление архива | Новый volume: GET вернул 4, POST вернул 5 |
| Очистка | Временные контейнеры, сети и volumes удалены через trap |

Оба полных запуска использовали разные проекты и изначально пустые volumes.
Каждый завершился строкой:

```text
PASS: все проверки пройдены; тестовые ресурсы удалены.
```

Два архива сохранены локально в `backups/` и исключены из Git.
Скрипт создаёт их заново при каждом запуске.
