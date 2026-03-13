# Check Parameters SQL Server for 1C

Набор инструментов (T-SQL скрипты + PowerShell) для проверки готовности и оптимальности настроек Microsoft SQL Server согласно рекомендациям 1С для крупных технологических решений.

Источник рекомендаций: https://its.1c.ru/db/metod8dev#browse:13:-1:3199:3258

## Назначение

Автоматизированная проверка параметров SQL Server на соответствие рекомендациям 1С:
- Параметры экземпляра (max memory, MAXDOP, cost threshold for parallelism)
- Конфигурация TempDB (количество файлов, размеры, автоприрост)
- Модель восстановления и настройки журналов транзакций
- Статистика и индексы баз данных
- Сетевые параметры и параметры ОС
- Дисковая подсистема и производительность I/O
- План обслуживания (maintenance plan)
- Флаги трассировки (trace flags)

## Tech Stack

- **T-SQL** — скрипты проверки параметров внутри SQL Server
- **PowerShell** — проверка параметров ОС, сети, дисков, конфигурации сервера
- **Целевая платформа:** Microsoft SQL Server 2016+ / Windows Server

## Структура проекта

```
scripts/
  sql/              # T-SQL скрипты проверки
    server/         # Параметры экземпляра SQL Server
    tempdb/         # Конфигурация TempDB
    database/       # Параметры баз данных (модель восстановления, статистика, индексы)
    performance/    # Ожидания, блокировки, планы запросов
    maintenance/    # План обслуживания, бэкапы
  powershell/       # PowerShell скрипты
    os/             # Параметры ОС (память, CPU, электропитание)
    disk/           # Дисковая подсистема, I/O
    network/        # Сетевые параметры
    config/         # Конфигурация SQL Server (trace flags, startup params)
reports/            # Шаблоны отчётов
docs/               # Документация
```

## Команды

```bash
# Запуск PowerShell-скрипта
pwsh -File scripts/powershell/<script>.ps1

# Запуск SQL-скрипта через sqlcmd
sqlcmd -S <server> -d master -i scripts/sql/<script>.sql

# Запуск всех проверок
pwsh -File scripts/Run-AllChecks.ps1 -ServerName <server>
```

## Соглашения по коду

- Комментарии в SQL и PowerShell на **русском языке**
- Каждый скрипт проверки — самодостаточный, можно запускать отдельно
- Вывод результатов: текстовый отчёт с указанием статуса (OK / WARNING / CRITICAL)
- Имена файлов: `Check-<Area>-<Parameter>.sql` / `Check-<Area>-<Parameter>.ps1`
- SQL скрипты совместимы с SQL Server 2016+
- PowerShell 5.1+ (Windows) или PowerShell 7+ (кроссплатформенный)
- В каждом скрипте указывать ссылку на соответствующий раздел рекомендаций 1С

## Claude Automations

### Skills

**Workflow:**
- `/orchestrate` — Full development cycle (Plan > Code > Test > Review > Fix > Document). For complex multi-step features.
- `/implement` — Simple workflow (Code > Test > Document). For single components or endpoints.
- `/012-update-docs` — Post-task documentation verification.

**Quality:**
- `/code-review` — Manual code review for quality, bugs, security, best practices.
- `/arch-review` — Architecture review for design patterns, SOLID, dependencies.
- `/security-audit` — Security vulnerability audit (OWASP Top 10).
- `/refactor-code` — Guided code refactoring without behavior change.

### Agents

**Pipeline** (used by `/orchestrate` and `/implement`):
- `planner` — Break task into subtasks with dependencies
- `worker` — Implement code for each subtask
- `test-runner` — Run lint + tests + verify
- `debugger` — Fix issues from test/review/security reports
- `reviewer` — Code quality review
- `security-auditor` — Security vulnerability scanning
- `documenter` — Create completion report
- `doc-keeper` — Analyze doc drafts, recommend and apply doc updates
- `observer` — Analyze orchestration run, identify improvements

**Quality** (used by standalone quality skills):
- `senior-reviewer` — Architecture review with health scores (used by `/arch-review`)
- `refactor` — Code refactoring specialist (used by `/refactor-code`)

### Hooks

- **SubagentStop**: Pipeline transition hints for all 9 agents
- **PreToolUse**: Safety guard blocking `rm -rf`, `git push --force`, `git reset --hard`

### Config

- `.claude/orchestration-config.json` — Paths and toggles for AI-generated artifacts (plans, reports, issues, doc-drafts, observer-reports)
