-- ============================================================================
-- Collect-MSSQL-1C-PerDB.sql
-- ----------------------------------------------------------------------------
-- Назначение: per-DB блоки коллектора для итерации по нескольким 1С-базам.
-- Запускается PowerShell-модулем Invoke-MssqlDiagnostic.psm1 один раз для
-- каждой 1С-базы (через sqlcmd -d <DBNAME>). Все блоки используют DB_NAME()
-- и DB_ID() — никаких параметров через -v не требуется.
--
-- Контекст (bd 70e): основной коллектор Collect-MSSQL-1C-Data.sql эмитит
-- _apl_<dbname> и _stale_stats_* только для текущей подключённой базы (по
-- умолчанию master, где блоки заглушены через AND DB_ID() > 4). Чтобы
-- покрыть multi-DB инстансы, PowerShell-модуль:
--   1. Запускает основной коллектор (master или указанная Database).
--   2. Через Find-1CDatabasesOnMssql получает список 1С-баз.
--   3. Для каждой 1С-базы запускает этот скрипт с -d <dbname>.
--   4. Аппендит полученные строки к результатам основного коллектора.
--
-- Формат вывода идентичен основному коллектору (pipe-разделённый, 6 полей):
--   N | Section | Key | Label | Display | Value
-- ============================================================================

SET NOCOUNT ON;

-- ALLOW_PAGE_LOCKS distribution per DB (признак платформы 8.3.22+)
SELECT 400 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'statistics' AS "Section",
       '_apl_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'ALLOW_PAGE_LOCKS в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CONVERT(NVARCHAR(20),
         SUM(CASE WHEN allow_page_locks = 0 THEN 1 ELSE 0 END))
       + N' OFF из ' + CONVERT(NVARCHAR(20), COUNT(*))
       + ' (' + CONVERT(NVARCHAR(20),
           CAST(100.0 * SUM(CASE WHEN allow_page_locks = 0 THEN 1 ELSE 0 END) /
                NULLIF(COUNT(*), 0) AS DECIMAL(5,1))) + ' %)' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"no_page_locks":' + CONVERT(NVARCHAR(20),
             SUM(CASE WHEN allow_page_locks = 0 THEN 1 ELSE 0 END))
         + ',"total_indexes":' + CONVERT(NVARCHAR(20), COUNT(*))
         + ',"pct":' + CONVERT(NVARCHAR(20),
             CAST(100.0 * SUM(CASE WHEN allow_page_locks = 0 THEN 1 ELSE 0 END) /
                  NULLIF(COUNT(*), 0) AS DECIMAL(5,1)))
         + '}'
       ) AS "Value"
FROM sys.indexes
WHERE type IN (1, 2)  -- clustered, nonclustered
  AND DB_ID() > 4     -- защита: per-DB скрипт не должен запускаться против системных баз
HAVING COUNT(*) > 0;
GO

-- УСТАРЕВШАЯ СТАТИСТИКА (топ-20 по modification_counter в текущей БД)
SELECT 600 + ROW_NUMBER() OVER (ORDER BY sp.modification_counter DESC) AS "N",
       'runtime' AS "Section",
       '_stale_stats_' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '_'
         + CONVERT(NVARCHAR(10), s.object_id) + '_'
         + CONVERT(NVARCHAR(10), s.stats_id) AS "Key",
       N'Статистика: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_SCHEMA_NAME(s.object_id) COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_NAME(s.object_id) COLLATE DATABASE_DEFAULT) + ' / ' + (s.name COLLATE DATABASE_DEFAULT) AS "Label",
       N'возраст=' + ISNULL(CONVERT(NVARCHAR(20),
           DATEDIFF(DAY, sp.last_updated, GETDATE())), '?') + N' дн / '
       + N'строк=' + CONVERT(NVARCHAR(20), sp.rows)
       + N' / изменений=' + CONVERT(NVARCHAR(20), sp.modification_counter) AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"table":"' + (OBJECT_SCHEMA_NAME(s.object_id) COLLATE DATABASE_DEFAULT) + '.' + (OBJECT_NAME(s.object_id) COLLATE DATABASE_DEFAULT) + '"'
         + ',"stats":"' + (s.name COLLATE DATABASE_DEFAULT) + '"'
         + ',"last_updated":"' + ISNULL(CONVERT(NVARCHAR(30), sp.last_updated, 126), '') + '"'
         + ',"rows":' + CONVERT(NVARCHAR(20), sp.rows)
         + ',"modification_counter":' + CONVERT(NVARCHAR(20), sp.modification_counter)
         + ',"days_old":' + ISNULL(CONVERT(NVARCHAR(20),
             DATEDIFF(DAY, sp.last_updated, GETDATE())), 'null')
         + '}'
       ) AS "Value"
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE (sp.last_updated < DATEADD(DAY, -3, GETDATE())
       OR sp.modification_counter > 100000)
  AND DB_ID() > 4
ORDER BY sp.modification_counter DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO
