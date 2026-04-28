# Anamnesis Kit

Длительное наблюдение за MS SQL Server во время инцидента 1С (зависающий расчёт ЕСХН, закрытие месяца, перепроведение). Клиент собирает таймсерию снимков → бэкенд классифицирует → постоянная HTML-ссылка с вердиктом.

## Быстрый старт (для оператора)

После установки через `install-anamnesis.ps1` всё делается через интерактивное меню:

```powershell
C:\Anamnesis\Run-Anamnesis.ps1
```

Пять пунктов: README → setup SQL → запустить watcher (отдельное окно с live-прогрессом) → остановить и отправить архив → выход. Меню само спросит имя SQL Server и БД.

`install-anamnesis.ps1` запускает это меню автоматически после распаковки.

## Структура каталога

| Файл / папка | Назначение |
|---|---|
| [`Run-Anamnesis.ps1`](Run-Anamnesis.ps1) | Интерактивное меню — главная точка входа |
| [`setup/01-enable-query-store.sql`](setup/01-enable-query-store.sql) | Query Store + Auto Plan Correction на целевой БД |
| [`setup/02-set-blocked-process-threshold.sql`](setup/02-set-blocked-process-threshold.sql) | BPT = 10 sec (нужен для XE blocked-process-report) |
| [`setup/03-create-xe-session.sql`](setup/03-create-xe-session.sql) | XE-сессия `_diag_eshn_hang` (>5s queries + blocked process report) |
| [`setup/99-cleanup.sql`](setup/99-cleanup.sql) | Откат всех Layer 1 настроек, идемпотентно |
| [`watcher/Snapshot-OneShot.sql`](watcher/Snapshot-OneShot.sql) | T-SQL: 7 секций DMV → одна строка JSON-столбцов |
| [`watcher/Snapshot-OneShot.ps1`](watcher/Snapshot-OneShot.ps1) | PS-обёртка: вызов SQL, запись `snap-yyyyMMdd-HHmmss.json` |
| [`watcher/Start-Watcher.ps1`](watcher/Start-Watcher.ps1) | Регистрирует scheduled task `_DiagEshnWatcher` (каждые 30 сек, N часов) |
| [`watcher/Stop-Watcher.ps1`](watcher/Stop-Watcher.ps1) | Снимает scheduled task |
| [`upload/Upload-Archive.ps1`](upload/Upload-Archive.ps1) | Пакует snap-*.json в tar.gz, шлёт на бэкенд через curl.exe (PS 5.1 ок) |
| `data/snapshots/`, `data/xe/`, `data/archives/` | Создаются `install-anamnesis.ps1` для runtime-артефактов |
| `analyze/` | **Внутренний** агрегатор + классификатор; в публичный релиз не попадает |

## Граница «клиент / бэкенд»

На клиентской машине — **только сбор и отправка**. Никаких порогов, классификаторов, правил классификации. Это и защита IP, и архитектурный принцип единого источника истины.

Весь анализ — на бэкенде:
- Эндпоинты: [`backend/app/api/v1/anamnesis.py`](../../backend/app/api/v1/anamnesis.py) — `POST /upload`, `GET /{id}/html`, `GET /{id}/archive`
- Классификатор + 6 вердиктов: [`backend/app/anamnesis/verdict_builder.py`](../../backend/app/anamnesis/verdict_builder.py)
- Агрегатор: [`backend/app/anamnesis/aggregator.py`](../../backend/app/anamnesis/aggregator.py)
- Модель БД: [`backend/app/db/models.py`](../../backend/app/db/models.py) — `class AnamnesisSession`
- HTML-шаблон: [`backend/app/reports/templates/report_anamnesis.html`](../../backend/app/reports/templates/report_anamnesis.html)

Реестр того, что попадает в публичный релиз vs остаётся приватным: [`.public-include`](../../.public-include).

## Шесть вердиктов классификатора

| Verdict | Когда срабатывает | Куда копать |
|---|---|---|
| `IO_BOUND` | `PAGEIOLATCH_SH+EX > 50%` времени окна и `max logical_reads > 10M` | buffer pool / scan vs seek |
| `LOCK_BOUND` | `LCK_M_* > 10%` и head blocker `> 30 sec` | RCSI, управляемые блокировки |
| `PARAMETER_SNIFFING` | Query Store показывает ≥2 плана для query_id, ratio max/min duration `> 5x` | Auto Plan Correction |
| `MEMORY_GRANT_BOUND` | `RESOURCE_SEMAPHORE > 5%` или хоть один undergranted grant | max server memory, плохой план |
| `PARALLELISM_BOUND` | `CXPACKET > 30%` и server `MAXDOP > 1` | Cost Threshold = 25–50 |
| `LOGIC_BOUND` | fallback, ничего другого не сработало | профилировать 1С-код через ТЖ |

Пороговые значения: [`backend/app/anamnesis/constants.py`](../../backend/app/anamnesis/constants.py).

## Для агентов, работающих над kit

Контекст и история в этих документах (приватные, не попадают в релиз):

- Spec клиентского MVP: [`docs/superpowers/specs/2026-04-28-mssql-eshn-anamnesis-design.md`](../../docs/superpowers/specs/2026-04-28-mssql-eshn-anamnesis-design.md)
- Spec бэкенд-интеграции: [`docs/superpowers/specs/2026-04-28-anamnesis-backend-design.md`](../../docs/superpowers/specs/2026-04-28-anamnesis-backend-design.md)
- План реализации: [`docs/superpowers/plans/2026-04-28-anamnesis-backend-integration.md`](../../docs/superpowers/plans/2026-04-28-anamnesis-backend-integration.md)
- Операционный runbook: [`docs/runbook-anamnesis.md`](../../docs/runbook-anamnesis.md)
- Deep research «что обычно упускают на MS SQL под 1С»: [`docs/research/mssql-1c-overlooked-causes-20260428/REPORT.md`](../../docs/research/mssql-1c-overlooked-causes-20260428/REPORT.md)
- Gap analysis коллектора vs deep-research: [`docs/research/eshn-collector-gap-analysis-20260428.md`](../../docs/research/eshn-collector-gap-analysis-20260428.md)
- Code review текущей реализации: [`docs/research/code-review-anamnesis-backend-20260428.md`](../../docs/research/code-review-anamnesis-backend-20260428.md)
- Beads-эпик деплоя бэкенда: `bd show check-parameters-sql-server-for-1c-dzp` (закрыт)

Тестовые фикстуры (25 файлов, 5 сценариев) живут в `analyze/tests/fixtures/` и **переиспользуются** Python-тестами бэкенда: [`backend/tests/anamnesis/conftest.py`](../../backend/tests/anamnesis/conftest.py). Один источник истины — Python и PowerShell классификаторы должны давать одинаковые вердикты на одинаковых входных.

## Версионирование

- Версии независимые: `version` (основной коллектор) и `anamnesis_kit_version` в [`project.json`](../../project.json).
- Любое изменение в kit'е → бамп `anamnesis_kit_version` → `./scripts/publish-to-public.sh "описание"` → новый GitHub Release с zip-артефактом.
- `install-anamnesis.ps1` берёт `latest` release; конкретную версию — параметром `-Version v1.1.0`.
- В клиентский релиз попадает один общий zip `1c-diagnostic-vX.Y.Z.zip`, `install-anamnesis.ps1` извлекает из него только `scripts/anamnesis/*` + `project.json`.
