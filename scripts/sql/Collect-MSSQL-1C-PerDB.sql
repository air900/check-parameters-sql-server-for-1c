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

-- СВОДКА ПО СТАТИСТИКАМ В БД (агрегат). Один summary-row на БД с числовыми
-- метриками устаревания. Threshold для high_change: modification_counter > 20%
-- от rows, и только для таблиц >1000 строк (чтобы не ловить мелочь). Это
-- industry-standard порог обновления (Ola Hallengren, Microsoft).
SELECT 410 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'statistics' AS "Section",
       '_stats_summary_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Состояние статистики БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CONVERT(NVARCHAR(20), COUNT(*)) + N' статистик / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7  THEN 1 ELSE 0 END))
           + N' старше 7 дн / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 30 THEN 1 ELSE 0 END))
           + N' старше 30 дн / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN sp.modification_counter > 0.2 * sp.rows AND sp.rows > 1000 THEN 1 ELSE 0 END))
           + N' с >20% изменений / макс возраст '
         + ISNULL(CONVERT(NVARCHAR(20), MAX(DATEDIFF(DAY, sp.last_updated, GETDATE()))), '0')
           + N' дн' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"total":'             + CONVERT(NVARCHAR(20), COUNT(*))
         + ',"older_7d":'          + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7  THEN 1 ELSE 0 END))
         + ',"older_30d":'         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 30 THEN 1 ELSE 0 END))
         + ',"high_change":'       + CONVERT(NVARCHAR(20), SUM(CASE WHEN sp.modification_counter > 0.2 * sp.rows AND sp.rows > 1000 THEN 1 ELSE 0 END))
         + ',"max_age_days":'      + ISNULL(CONVERT(NVARCHAR(20), MAX(DATEDIFF(DAY, sp.last_updated, GETDATE()))), '0')
         + ',"total_modifications":' + CONVERT(NVARCHAR(20), ISNULL(SUM(CAST(sp.modification_counter AS BIGINT)), 0))
         + '}'
       ) AS "Value"
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
  AND DB_ID() > 4;
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
WHERE DB_ID() > 4
  -- Только USER tables (без sys.* шума).
  AND OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
  -- Значимый размер — мелкие справочники (rows < 1000) даже устаревшие
  -- не дают шанса на серьёзное расхождение оценок оптимизатора.
  AND sp.rows > 1000
  -- Industry-standard signal «нужно обновить» — Ola Hallengren default:
  -- modification_counter > 20% строк. Сам по себе age НЕ показатель качества
  -- статистики (статичный справочник 365-дневной давности — корректная стат).
  -- Erin Stellato (SQLskills): "Track modification %, not age".
  AND sp.modification_counter > 0.2 * sp.rows
ORDER BY (CAST(sp.modification_counter AS DECIMAL(20,1)) / NULLIF(sp.rows, 0)) DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO

-- ============================================================================
-- bd 37r: ФРАГМЕНТАЦИЯ ИНДЕКСОВ — per-DB summary + TOP-20 (только USER tables).
-- DMV mode 'LIMITED' — читает root + intermediate-pages, безопасно для prod
-- (S-lock на metadata, никакого скана данных). На 1 TB ERP занимает 5-30 сек.
-- Фильтры: page_count > 1000 (≥ 8 MB — мелкие индексы Microsoft рекомендует
-- игнорировать), index_id > 0 (heap не имеет фрагментации), IsUserTable.
-- ============================================================================

-- Per-DB summary (один row на БД)
SELECT 420 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'maintenance' AS "Section",
       '_index_fragmentation_summary_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Состояние фрагментации индексов БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       -- ISNULL на каждый агрегат: SUM/MAX над пустым набором возвращают NULL,
       -- любая string concat с NULL → NULL → Display/Value становятся 'NULL'.
       -- COUNT(*) всегда возвращает 0 на пустом наборе, его не нужно защищать.
       CONVERT(NVARCHAR(20), COUNT(*)) + N' индексов / '
         + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent > 30 THEN 1 ELSE 0 END), 0))
           + N' с frag>30% / '
         + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent BETWEEN 5 AND 30 THEN 1 ELSE 0 END), 0))
           + N' с frag 5-30% / макс '
         + CONVERT(NVARCHAR(20), CAST(ISNULL(MAX(ips.avg_fragmentation_in_percent), 0) AS DECIMAL(5,1)))
           + N' %' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"total":'              + CONVERT(NVARCHAR(20), COUNT(*))
         + ',"high_frag_count":'    + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent > 30 THEN 1 ELSE 0 END), 0))
         + ',"medium_frag_count":'  + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent BETWEEN 5 AND 30 THEN 1 ELSE 0 END), 0))
         + ',"max_frag_pct":'       + CONVERT(NVARCHAR(20), CAST(ISNULL(MAX(ips.avg_fragmentation_in_percent), 0) AS DECIMAL(5,1)))
         + ',"high_frag_size_mb":'  + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent > 30 THEN ips.page_count * 8 / 1024 ELSE 0 END), 0))
         + '}'
       ) AS "Value"
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.page_count > 1000               -- ≥ 8 MB (мелкие индексы — шум)
  AND ips.index_id > 0                    -- heap (index_id=0) — нет фрагментации
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
  AND DB_ID() > 4;
GO

-- TOP-20 фрагментированных индексов, сортировка по impact = pct × size
SELECT 700 + ROW_NUMBER() OVER (ORDER BY ips.avg_fragmentation_in_percent * ips.page_count DESC) AS "N",
       'runtime' AS "Section",
       '_index_top_fragmented_' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '_'
         + CONVERT(NVARCHAR(10), ips.object_id) + '_'
         + CONVERT(NVARCHAR(10), ips.index_id) AS "Key",
       N'Индекс: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_SCHEMA_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + ' / ' + (i.name COLLATE DATABASE_DEFAULT) AS "Label",
       N'frag=' + CONVERT(NVARCHAR(20), CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1))) + N'% / size='
       + CONVERT(NVARCHAR(20), ips.page_count * 8 / 1024) + N' MB' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"table":"' + (OBJECT_SCHEMA_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + '.' + (OBJECT_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + '"'
         + ',"index":"' + (i.name COLLATE DATABASE_DEFAULT) + '"'
         + ',"frag_pct":'   + CONVERT(NVARCHAR(20), CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1)))
         + ',"page_count":' + CONVERT(NVARCHAR(20), ips.page_count)
         + ',"size_mb":'    + CONVERT(NVARCHAR(20), ips.page_count * 8 / 1024)
         + '}'
       ) AS "Value"
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.page_count > 1000
  AND ips.index_id > 0
  AND ips.avg_fragmentation_in_percent > 30   -- только HIGH (что требует REBUILD)
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
  AND DB_ID() > 4
ORDER BY ips.avg_fragmentation_in_percent * ips.page_count DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO
