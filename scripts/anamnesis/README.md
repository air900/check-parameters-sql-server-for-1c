# Anamnesis Kit — quick start

## За 5 шагов от «расчёт зависает» до verdict

```bash
# 0. Однократно (раз в жизни сервера):
#    Папки data/snapshots, data/xe, data/archives создаются install-anamnesis.ps1 автоматически.
sqlcmd -S MSSQL-TEST -i setup\01-enable-query-store.sql -v db=eshn_test1
sqlcmd -S MSSQL-TEST -i setup\02-set-blocked-process-threshold.sql
sqlcmd -S MSSQL-TEST -i setup\03-create-xe-session.sql -v db=eshn_test1

# 1. За 5 минут до запуска расчёта:
.\watcher\Start-Watcher.ps1 -Server MSSQL-TEST -Database eshn_test1 -Hours 8

# 2. Запустить расчёт ЕСХН в 1С.

# 3. После расчёта (или после "сдался ждать"):
.\watcher\Stop-Watcher.ps1

# 4. Анализ (локальный):
.\analyze\Aggregate-Anamnesis.ps1 -SnapshotDir C:\Anamnesis\data\snapshots `
    -OutFile docs\anamnesis-eshn-YYYYMMDD.md

# 5. Прочитать verdict в начале файла → действовать по рекомендации.
```

См. полный runbook: [docs/runbook-anamnesis.md](../../docs/runbook-anamnesis.md)

### Шаг 4. Загрузка архива на бэкенд

```powershell
.\upload\Upload-Archive.ps1 `
    -SnapshotDir C:\Anamnesis\data\snapshots `
    -Database eshn_test1
```

В выводе будет постоянная ссылка на отчёт — её можно отправить клиенту.

## Что будет в отчёте

- **Verdict** (флаги): IO_BOUND, LOCK_BOUND, MEMORY_GRANT_BOUND, PARAMETER_SNIFFING, PARALLELISM_BOUND, LOGIC_BOUND.
- **Wait stats delta** в окне расчёта.
- **Top-3 запроса** по CPU.
- **Blocking events**, если были.
- **Memory grants summary**.
- **Tempdb hot spots**.
- **Query Store regressions**.

## Cleanup (откат всех изменений на сервере)

```bash
sqlcmd -S MSSQL-TEST -i setup\99-cleanup.sql -v db=eshn_test1 reset_qs=0
```
