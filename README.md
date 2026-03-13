# Check Parameters SQL Server for 1C

Набор инструментов для автоматической проверки настроек Microsoft SQL Server на соответствие рекомендациям 1С для крупных технологических решений.

## Что проверяется

| Область | Описание |
|---------|----------|
| Параметры экземпляра | Max memory, MAXDOP, cost threshold for parallelism |
| TempDB | Количество файлов, размеры, автоприрост |
| Базы данных | Модель восстановления, статистика, индексы |
| Производительность | Ожидания, блокировки, планы запросов |
| Обслуживание | Планы бэкапов, целостность, перестроение индексов |
| ОС и оборудование | Память, CPU, электропитание, дисковая подсистема |
| Сеть | Сетевые параметры SQL Server |
| Конфигурация | Trace flags, startup parameters |

## Источник рекомендаций

[Рекомендации 1С по администрированию MS SQL Server](https://its.1c.ru/db/metod8dev#browse:13:-1:3199:3258)

## Требования

- Microsoft SQL Server 2016+
- PowerShell 5.1+ (Windows) или PowerShell 7+
- Права sysadmin или VIEW SERVER STATE на SQL Server

## Быстрый старт

```bash
# Запуск всех проверок
pwsh -File scripts/Run-AllChecks.ps1 -ServerName <имя_сервера>

# Запуск отдельного SQL-скрипта
sqlcmd -S <сервер> -d master -i scripts/sql/server/Check-Server-MaxMemory.sql

# Запуск отдельного PowerShell-скрипта
pwsh -File scripts/powershell/os/Check-OS-PowerPlan.ps1
```

## Структура

```
scripts/
  sql/              # T-SQL скрипты проверки
    server/         # Параметры экземпляра
    tempdb/         # Конфигурация TempDB
    database/       # Параметры баз данных
    performance/    # Производительность
    maintenance/    # Обслуживание
  powershell/       # PowerShell скрипты
    os/             # Параметры ОС
    disk/           # Дисковая подсистема
    network/        # Сеть
    config/         # Конфигурация SQL Server
```

## Формат вывода

Каждый скрипт выводит результат со статусом:

- **OK** — параметр соответствует рекомендациям
- **WARNING** — отклонение, рекомендуется обратить внимание
- **CRITICAL** — параметр не соответствует рекомендациям, требуется исправление

## Лицензия

MIT
