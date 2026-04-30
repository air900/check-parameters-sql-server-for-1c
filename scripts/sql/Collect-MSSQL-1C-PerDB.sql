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
-- метриками устаревания.
--
-- bd 5h3 (v2.8.17): older_7d / older_30d / max_age_days теперь считают только
-- ЗНАЧИМЫЕ статистики — те, где rows >= 10000 И modification_counter > 0.
-- Раньше счётчик включал _WA_Sys_* auto-stats на крошечных таблицах с
-- modification_counter=0 (cardinality всё ещё точна, обновлять бессмысленно).
-- Поле finding на eshn_test1 1197 GB: было `older_7d=15786` (паника), реально
-- 99 % шум — мелочь без правок. После фильтра остаются только actionable
-- объекты.
--
-- threshold для high_change: modification_counter > 20% от rows, для таблиц
-- >1000 строк — оставлен как есть (industry-standard порог Ola Hallengren).
-- Поля total и total_modifications — НЕ фильтруются (общая инвентаризация).
SELECT 410 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'statistics' AS "Section",
       '_stats_summary_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Состояние статистики БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CONVERT(NVARCHAR(20), COUNT(*)) + N' статистик / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7
                                              AND sp.rows >= 10000
                                              AND sp.modification_counter > 0
                                         THEN 1 ELSE 0 END))
           + N' значимых старше 7 дн / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 30
                                              AND sp.rows >= 10000
                                              AND sp.modification_counter > 0
                                         THEN 1 ELSE 0 END))
           + N' значимых старше 30 дн / '
         + CONVERT(NVARCHAR(20), SUM(CASE WHEN sp.modification_counter > 0.2 * sp.rows AND sp.rows > 1000 THEN 1 ELSE 0 END))
           + N' с >20% изменений / макс возраст значимых '
         + ISNULL(CONVERT(NVARCHAR(20), MAX(CASE WHEN sp.rows >= 10000 AND sp.modification_counter > 0
                                                 THEN DATEDIFF(DAY, sp.last_updated, GETDATE())
                                                 ELSE NULL END)), '0')
           + N' дн' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"total":'             + CONVERT(NVARCHAR(20), COUNT(*))
         + ',"older_7d":'          + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7
                                                                         AND sp.rows >= 10000
                                                                         AND sp.modification_counter > 0
                                                                    THEN 1 ELSE 0 END))
         + ',"older_30d":'         + CONVERT(NVARCHAR(20), SUM(CASE WHEN DATEDIFF(DAY, sp.last_updated, GETDATE()) > 30
                                                                         AND sp.rows >= 10000
                                                                         AND sp.modification_counter > 0
                                                                    THEN 1 ELSE 0 END))
         + ',"high_change":'       + CONVERT(NVARCHAR(20), SUM(CASE WHEN sp.modification_counter > 0.2 * sp.rows AND sp.rows > 1000 THEN 1 ELSE 0 END))
         + ',"max_age_days":'      + ISNULL(CONVERT(NVARCHAR(20), MAX(CASE WHEN sp.rows >= 10000 AND sp.modification_counter > 0
                                                                            THEN DATEDIFF(DAY, sp.last_updated, GETDATE())
                                                                            ELSE NULL END)), '0')
         + ',"total_modifications":' + CONVERT(NVARCHAR(20), ISNULL(SUM(CAST(sp.modification_counter AS BIGINT)), 0))
         + '}'
       ) AS "Value"
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
JOIN sys.tables t WITH (NOLOCK) ON s.object_id = t.object_id   -- bd 5h3: column lookup быстрее OBJECTPROPERTY()
WHERE t.is_ms_shipped = 0
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

-- ============================================================================
-- bd nbf: КРУПНЫЕ НЕСЖАТЫЕ ТАБЛИЦЫ (>10 GB, ни один partition не сжат).
-- На Enterprise edition сжатие даёт 2-3× по размеру → меньше IO. Для 1С это
-- регистры накопления, итоги, движения регистраторов. Источник: gilev.ru,
-- assets/mssql/gilev.ru/46-mssql-compress-table.md → правило mssql_no_compression_on_large_table.
-- Per-DB summary (один row на БД): сколько user-таблиц >10 GB живут без сжатия.
--
-- bd 4rz (v2.8.16): переписано через sys.dm_db_partition_stats. Прежняя версия
-- (sys.tables × sys.partitions × sys.allocation_units) висла 8+ минут на 1ТБ
-- БД (eshn_test1, 14M логических чтений, 6 мин CPU). Allocation_units — это
-- внутренний реестр размещения с десятками миллионов строк на крупных БД;
-- DMV dm_db_partition_stats хранит pre-aggregated reserved_page_count на
-- партицию → джоин с allocation_units не нужен. NOLOCK на каталог-views — для
-- read-only диагностики (если в момент сбора кто-то делает DDL, чуть устаревшая
-- метаданная безопаснее, чем ожидание Sch-S).
-- ============================================================================

;WITH sizes AS (
    -- DMV pre-aggregated по партиции — sum даёт размер таблицы за один скан.
    SELECT object_id,
           SUM(reserved_page_count) AS pages
    FROM sys.dm_db_partition_stats
    GROUP BY object_id
), compression AS (
    -- data_compression — атрибут партиции. MAX отвечает на вопрос «сжата ли
    -- хоть одна партиция»: если max=0, значит ВСЕ партиции в NONE → таблица
    -- целиком несжата.
    SELECT object_id, MAX(data_compression) AS max_compression
    FROM sys.partitions WITH (NOLOCK)
    GROUP BY object_id
), large_uncompressed AS (
    SELECT t.object_id,
           c.max_compression,
           s.pages * 8 / 1024 AS size_mb
    FROM sizes s
    JOIN compression c ON s.object_id = c.object_id
    JOIN sys.tables t WITH (NOLOCK) ON s.object_id = t.object_id
    WHERE t.is_ms_shipped = 0                       -- column lookup быстрее OBJECTPROPERTY()
      AND s.pages * 8 / 1024 > 10240                -- > 10 GB
      AND c.max_compression = 0                     -- 0 = NONE
)
SELECT 440 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'maintenance' AS "Section",
       '_large_uncompressed_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Крупные несжатые таблицы (>10 ГБ) в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       -- ISNULL: SUM/MAX на пустом наборе → NULL → string concat ломается на 'NULL'.
       CONVERT(NVARCHAR(20), COUNT(*)) + N' таблиц / макс '
         + CONVERT(NVARCHAR(20), ISNULL(MAX(size_mb) / 1024, 0)) + N' GB' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"count":'      + CONVERT(NVARCHAR(20), COUNT(*))
         + ',"max_size_mb":'+ CONVERT(NVARCHAR(20), ISNULL(MAX(size_mb), 0))
         + ',"sum_size_mb":'+ CONVERT(NVARCHAR(20), ISNULL(SUM(size_mb), 0))
         + '}'
       ) AS "Value"
FROM large_uncompressed
WHERE DB_ID() > 4;
GO

-- ============================================================================
-- bd 5ni (v1.7-B): DATABASE-SCOPED CONFIGURATIONS — расширение с 1 до 5 опций.
-- ----------------------------------------------------------------------------
-- sys.database_scoped_configurations — catalog VIEW без параметров, возвращает
-- настройки только текущей БД. View появилась в SQL 2016 RTM (ProductMajorVersion = 13).
-- На SQL ≤ 2014 ссылка падает при PARSE-time → оборачиваем в sp_executesql.
--
-- Опции, которые фильтруем:
--   LEGACY_CARDINALITY_ESTIMATION  — bd fuo (v1.6, переехал из старого _legacy_ce_*)
--   MAXDOP                         — per-DB override max degree of parallelism
--   PARAMETER_SNIFFING             — anti-workaround для нестабильных планов
--   QUERY_OPTIMIZER_HOTFIXES       — per-DB override TF 4199
--   ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY — SQL 2022+, на старых не вернёт строку
--
-- На каждую найденную опцию эмитится одна строка с ключом _dsc_<name_lower>_<dbname>.
-- PowerShell-агрегатор (Invoke-MssqlDiagnostic.psm1) разбирает по полю name
-- в JSON Value и формирует:
--   legacy_cardinality_estimator_db_count   (старый ключ — backward-compat для
--                                            mssql_legacy_cardinality_estimator_on)
--   dsc_maxdop_override_db_count            (v1.7-B новое)
--   dsc_parameter_sniffing_off_db_count     (v1.7-B новое)
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
    AND DB_ID() > 4
BEGIN
    EXEC sp_executesql N'
    SELECT 450 + ROW_NUMBER() OVER (ORDER BY name) AS "N",
           ''instance_config'' AS "Section",
           ''_dsc_'' + LOWER(name COLLATE DATABASE_DEFAULT)
                    + ''_'' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
           N''Override "'' + name + N''" в БД: '' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
           CONVERT(NVARCHAR(MAX), [value]) AS "Display",
           CONVERT(NVARCHAR(MAX),
             ''{"db":"'' + (DB_NAME() COLLATE DATABASE_DEFAULT) + ''"''
             + '',"name":"'' + name + ''"''
             + '',"value":'' + CONVERT(NVARCHAR(MAX), [value])
             + ''}''
           ) AS "Value"
    FROM sys.database_scoped_configurations
    WHERE (name COLLATE DATABASE_DEFAULT) IN (
        ''LEGACY_CARDINALITY_ESTIMATION'',
        ''MAXDOP'',
        ''PARAMETER_SNIFFING'',
        ''QUERY_OPTIMIZER_HOTFIXES'',
        ''ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY''
    )';
END
GO

-- ============================================================================
-- bd 5ni (v1.7-A): QUERY STORE state per-DB.
-- ----------------------------------------------------------------------------
-- sys.database_query_store_options — catalog view, появилась в SQL 2016 RTM.
-- Гейт по ProductMajorVersion >= 13 + sp_executesql (deferred parse).
-- Семантика actual_state: 0=OFF, 1=READ_ONLY (заполнен), 2=READ_WRITE (норма), 3=ERROR.
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
    AND DB_ID() > 4
BEGIN
    EXEC sp_executesql N'
    SELECT 460 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
           ''query_store'' AS "Section",
           ''_query_store_'' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
           N''Query Store в БД: '' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
           CASE qso.actual_state
                WHEN 0 THEN N''OFF''
                WHEN 1 THEN N''READ_ONLY (хранилище переполнено)''
                WHEN 2 THEN N''READ_WRITE (норма)''
                WHEN 3 THEN N''ERROR''
           END
           + N'' / capture='' + qso.query_capture_mode_desc
           + N'' / max '' + CONVERT(NVARCHAR(20), qso.max_storage_size_mb) + N'' MB'' AS "Display",
           CONVERT(NVARCHAR(MAX),
             ''{"db":"'' + (DB_NAME() COLLATE DATABASE_DEFAULT) + ''"''
             + '',"actual_state":'' + CONVERT(NVARCHAR(10), qso.actual_state)
             + '',"max_storage_size_mb":'' + CONVERT(NVARCHAR(20), qso.max_storage_size_mb)
             + '',"current_storage_size_mb":'' + CONVERT(NVARCHAR(20), qso.current_storage_size_mb)
             + ''}''
           ) AS "Value"
    FROM sys.database_query_store_options qso';
END
GO

-- ============================================================================
-- bd 5ni (v1.7-C): TRUSTWORTHY = ON per-DB (security).
-- ----------------------------------------------------------------------------
-- sys.databases.is_trustworthy_on есть с SQL 2005, version-gate не нужен.
-- На чистом 1С-инстансе должно быть всегда 0. Любая включённая 1С-БД с
-- TRUSTWORTHY ON = security escalation surface (sp_Blitz красным).
-- ============================================================================

SELECT 480 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'security' AS "Section",
       '_trustworthy_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'TRUSTWORTHY в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CASE WHEN d.is_trustworthy_on = 1 THEN N'ВКЛЮЧЕНО (риск)' ELSE N'выключено' END AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"trustworthy_on":' + CONVERT(NVARCHAR(1), d.is_trustworthy_on)
         + '}'
       ) AS "Value"
FROM sys.databases d
WHERE d.database_id = DB_ID() AND d.database_id > 4;
GO

-- ============================================================================
-- bd 5ni (v1.7-D): ACCELERATED DATABASE RECOVERY (ADR) per-DB (SQL 2019+).
-- ----------------------------------------------------------------------------
-- sys.databases.is_accelerated_database_recovery_on появился в SQL 2019
-- (ProductMajorVersion = 15). Эмитим только на 2019+, иначе ничего — на старых
-- ADR не существует как фичи.
--
-- В JSON эмитим size_gb из sys.database_files чтобы PowerShell-rollup мог
-- срабатывать только для крупных БД (правило mssql_adr_disabled_on_large_db
-- ловит "ADR off на БД > 100 GB").
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 15
    AND DB_ID() > 4
BEGIN
    EXEC sp_executesql N'
    SELECT 490 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
           ''recovery'' AS "Section",
           ''_adr_'' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
           N''Ускоренное восстановление БД: '' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
           CASE WHEN d.is_accelerated_database_recovery_on = 1
                THEN N''включено'' ELSE N''выключено'' END
           + N'' / размер '' + CONVERT(NVARCHAR(20),
                ISNULL((SELECT SUM(size) * 8 / 1024 / 1024
                        FROM sys.database_files WHERE type = 0), 0))
           + N'' GB'' AS "Display",
           CONVERT(NVARCHAR(MAX),
             ''{"db":"'' + (DB_NAME() COLLATE DATABASE_DEFAULT) + ''"''
             + '',"adr_on":'' + CONVERT(NVARCHAR(1), d.is_accelerated_database_recovery_on)
             + '',"size_gb":'' + CONVERT(NVARCHAR(20),
                 ISNULL((SELECT SUM(size) * 8 / 1024 / 1024
                         FROM sys.database_files WHERE type = 0), 0))
             + ''}''
           ) AS "Value"
    FROM sys.databases d
    WHERE d.database_id = DB_ID()';
END
GO

-- ============================================================================
-- bd awg (v2.10.0): 1C WORKLOAD PROFILE — категоризация по naming convention.
-- ----------------------------------------------------------------------------
-- Платформа 1С создаёт таблицы с predictable префиксами: _Reference<NNN> для
-- справочников, _Document<NNN> для документов, _AccumReg<NNN> для регистров и
-- т.д. Это позволяет извлечь "профиль нагрузки" БД (сколько справочной
-- информации, сколько движений регистров, сколько проводок) без знания
-- конкретной конфигурации 1С — для сравнения характера разных 1С-БД и
-- понимания профиля независимо от физического размера (compression искажает,
-- свободное пространство в .mdf завышает).
--
-- Источник: docs/research/mssql-config-inventory-coverage-2026-04-27.md.
-- Стоимость: sys.dm_db_partition_stats — pre-aggregated DMV; запрос на 1ТБ-БД
-- с ~10k таблиц отрабатывает за < 1 сек.
--
-- Эмиттирует одну строку на категорию (только непустые), key = _1c_<cat>_<db>.
-- ============================================================================

;WITH categorized AS (
    SELECT t.object_id, t.name,
           CASE
                -- Табличные части любых документов/справочников/регистров (_<тип>NNN_VT<MMM>).
                -- Проверяется ПЕРВЫМ, иначе попадёт в parent type. Pattern '%\_VT%' с ESCAPE
                -- ловит подстроку '_VT' (через escape underscore-wildcard) — стандартное
                -- именование табличных частей.
                WHEN t.name LIKE '%\_VT%' ESCAPE '\' THEN 'tabular_section'

                -- Справочники / документы
                WHEN t.name LIKE '\_Reference%' ESCAPE '\'                                THEN 'reference'
                WHEN t.name LIKE '\_DocumentJournal%' ESCAPE '\'                          THEN 'document_journal'
                WHEN t.name LIKE '\_Document%' ESCAPE '\'                                 THEN 'document'

                -- Регистры накопления (1С использует Rg, не Reg).
                -- Порядок важен: AccumRgT, AccumRgOpt, AccumRgChngR — раньше общего AccumRg.
                WHEN t.name LIKE '\_AccumRgT%' ESCAPE '\'                                 THEN 'accumreg_totals'
                WHEN t.name LIKE '\_AccumRgOpt%' ESCAPE '\'                               THEN 'accumreg_totals'
                WHEN t.name LIKE '\_AccumRgChngR%' ESCAPE '\'                             THEN 'accumreg_movements'
                WHEN t.name LIKE '\_AccumRgDl%' ESCAPE '\'                                THEN 'accumreg_movements'
                WHEN t.name LIKE '\_AccumRg%' ESCAPE '\'                                  THEN 'accumreg_movements'

                -- Регистры сведений (включая срезы и регистрацию изменений)
                WHEN t.name LIKE '\_InfoRgChngR%' ESCAPE '\'                              THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRgSL%' ESCAPE '\'                                 THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRgSF%' ESCAPE '\'                                 THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRg%' ESCAPE '\'                                   THEN 'inforeg'

                -- Регистры бухгалтерии (включая extension data, аналитические итоги)
                WHEN t.name LIKE '\_AccRgChngR%' ESCAPE '\'                               THEN 'accreg'
                WHEN t.name LIKE '\_AccRgED%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRgAT%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRgCT%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRg%' ESCAPE '\'                                    THEN 'accreg'

                -- Регистры расчёта
                WHEN t.name LIKE '\_CalcRgChngR%' ESCAPE '\'                              THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgActPer%' ESCAPE '\'                             THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgRecalc%' ESCAPE '\'                             THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgDR%' ESCAPE '\'                                 THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRg%' ESCAPE '\'                                   THEN 'calcreg'

                -- Планы видов характеристик / счетов / перечисления / константы
                WHEN t.name LIKE '\_Chrc%' ESCAPE '\'                                     THEN 'chrc'
                WHEN t.name LIKE '\_Acc%' ESCAPE '\'                                      THEN 'accchrt'  -- after AccRg/AccumRg
                WHEN t.name LIKE '\_Enum%' ESCAPE '\'                                     THEN 'enum'
                WHEN t.name LIKE '\_Const%' ESCAPE '\'                                    THEN 'const'

                -- Узлы планов обмена / последовательности / задачи / бизнес-процессы
                WHEN t.name LIKE '\_Node%' ESCAPE '\'                                     THEN 'platform_other'
                WHEN t.name LIKE '\_Sequence%' ESCAPE '\'                                 THEN 'platform_other'
                WHEN t.name LIKE '\_Task%' ESCAPE '\'                                     THEN 'platform_other'
                WHEN t.name LIKE '\_BProc%' ESCAPE '\'                                    THEN 'platform_other'
                WHEN t.name LIKE '\_BPRg%' ESCAPE '\'                                     THEN 'platform_other'

                WHEN t.name LIKE '\_%' ESCAPE '\'                                         THEN 'platform_other'
                ELSE 'non_1c'
           END AS category
    FROM sys.tables t WITH (NOLOCK)
    WHERE t.is_ms_shipped = 0
), agg AS (
    SELECT c.category,
           COUNT(DISTINCT c.object_id) AS tables_count,
           ISNULL(SUM(ps.row_count), 0) AS total_rows,
           ISNULL(SUM(ps.reserved_page_count), 0) * 8 / 1024 AS size_mb
    FROM categorized c
    LEFT JOIN sys.dm_db_partition_stats ps WITH (NOLOCK)
        ON c.object_id = ps.object_id AND ps.index_id IN (0, 1)
    GROUP BY c.category
)
SELECT 800 + ROW_NUMBER() OVER (ORDER BY
            CASE category
                WHEN 'reference' THEN 1 WHEN 'document' THEN 2 WHEN 'document_journal' THEN 3
                WHEN 'accumreg_totals' THEN 4 WHEN 'accumreg_movements' THEN 5
                WHEN 'inforeg' THEN 6 WHEN 'accreg' THEN 7 WHEN 'calcreg' THEN 8
                WHEN 'chrc' THEN 9 WHEN 'accchrt' THEN 10 WHEN 'enum' THEN 11 WHEN 'const' THEN 12
                WHEN 'platform_other' THEN 13 ELSE 14
            END) AS "N",
       'workload' AS "Section",
       '_1c_' + agg.category + '_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Профиль 1С — ' + agg.category + N' в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CONVERT(NVARCHAR(20), agg.tables_count) + N' таблиц / '
         + CONVERT(NVARCHAR(20), agg.total_rows) + N' строк / '
         + CONVERT(NVARCHAR(20), agg.size_mb) + N' MB' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"category":"' + agg.category + '"'
         + ',"tables_count":' + CONVERT(NVARCHAR(20), agg.tables_count)
         + ',"total_rows":' + CONVERT(NVARCHAR(20), agg.total_rows)
         + ',"size_mb":' + CONVERT(NVARCHAR(20), agg.size_mb)
         + '}'
       ) AS "Value"
FROM agg
WHERE agg.tables_count > 0
  AND DB_ID() > 4;
GO

-- ============================================================================
-- v2.12 SUMMARY ROWS — server-wide aggregaты, эмитятся ОДИН РАЗ за инстанс.
-- ----------------------------------------------------------------------------
-- В отличие от per-DB строк выше (одна строка на текущую DB_NAME()), эти три
-- блока сканируют sys.databases / msdb напрямую и возвращают ОДИН JSON-массив
-- объектов (по объекту на каждую пользовательскую БД). Ключи фиксированные:
--   _tde_state_summary
--   _suspect_pages_summary
--   _checkdb_last_clean_summary
--
-- PowerShell-агрегатор (Invoke-MssqlDiagnostic.psm1) дедуплицирует строки по
-- Key через HashSet existingKeys → если этот скрипт прогоняется по N 1С-базам,
-- только первая копия попадает в итоговый JSON, остальные молча отбрасываются.
-- Это безопасно: содержимое всех копий идентично, так как запросы не зависят
-- от DB_ID()/DB_NAME() текущего соединения.
--
-- Backend (backend/app/engine/normalizer.py::flatten_per_db) ждёт RAW JSON
-- array. ISNULL(..., N'[]') гарантирует, что пустой набор станет пустым
-- массивом, а не NULL — иначе flatten пропустит правила вместо «zero counts».
--
-- Замечание: этот блок выполняется по разу на каждую 1С-БД (DBCC DBINFO в
-- цикле сканирует все user-БД сервера каждый раз) → избыточная работа на
-- multi-DB инстансах. Корректность не страдает (см. дедуп выше), но при
-- желании оптимизации блоки можно перенести в Collect-MSSQL-1C-Data.sql.
-- ============================================================================

-- ── TDE state per database ────────────────────────────────────────────────
-- VIEW SERVER STATE требуется для sys.dm_database_encryption_keys.
-- При недостатке прав → пустой массив; flatten корректно даст «нулевые» counts.
DECLARE @tde_json NVARCHAR(MAX);
BEGIN TRY
    SET @tde_json = (
        SELECT
            d.name AS database_name,
            CAST(d.is_encrypted AS BIT) AS is_encrypted,
            ek.encryption_state,
            CASE WHEN c.expiry_date IS NULL THEN NULL
                 ELSE DATEDIFF(DAY, GETDATE(), c.expiry_date)
            END AS certificate_expiry_days
        FROM sys.databases d
        LEFT JOIN sys.dm_database_encryption_keys ek ON ek.database_id = d.database_id
        LEFT JOIN sys.certificates c ON c.thumbprint = ek.encryptor_thumbprint
        WHERE d.database_id > 4
        FOR JSON PATH
    );
END TRY
BEGIN CATCH
    SET @tde_json = N'[]';
END CATCH;

SELECT 970 AS "N",
       'security' AS "Section",
       '_tde_state_summary' AS "Key",
       N'Состояние TDE по всем базам' AS "Label",
       N'' AS "Display",
       ISNULL(@tde_json, N'[]') AS "Value";
GO

-- ── msdb.dbo.suspect_pages — count per DB ─────────────────────────────────
-- Фиксированная системная таблица msdb. Без TRY/CATCH: если SELECT недоступен,
-- общий обработчик ошибок sqlcmd должен это поймать (а доступ к msdb для
-- учётной записи диагностики — стандартное предположение).
DECLARE @suspect_json NVARCHAR(MAX);
SET @suspect_json = (
    SELECT
        DB_NAME(database_id) AS database_name,
        COUNT(*) AS suspect_page_count
    FROM msdb.dbo.suspect_pages
    GROUP BY database_id
    FOR JSON PATH
);

SELECT 971 AS "N",
       'maintenance' AS "Section",
       '_suspect_pages_summary' AS "Key",
       N'Записи о повреждённых страницах по всем базам' AS "Label",
       N'' AS "Display",
       ISNULL(@suspect_json, N'[]') AS "Value";
GO

-- ── DBCC DBINFO — last clean DBCC CHECKDB per DB ──────────────────────────
-- Поле 'dbi_dbccLastKnownGood' стабильно с SQL 2008. NULL ⇒ CHECKDB либо
-- никогда не запускался успешно, либо БД недоступна (TRY/CATCH в цикле
-- защищает от потери всего набора при ошибке на одной базе).
IF OBJECT_ID('tempdb..#dbinfo') IS NOT NULL DROP TABLE #dbinfo;
CREATE TABLE #dbinfo (
    ParentObject NVARCHAR(255),
    [Object]     NVARCHAR(255),
    Field        NVARCHAR(255),
    [Value]      NVARCHAR(MAX)
);
IF OBJECT_ID('tempdb..#checkdb_results') IS NOT NULL DROP TABLE #checkdb_results;
CREATE TABLE #checkdb_results (database_name SYSNAME, last_clean_dbcc DATETIME NULL);

DECLARE @db_name SYSNAME;
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE' AND database_id > 4 AND HAS_DBACCESS(name) = 1;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db_name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        TRUNCATE TABLE #dbinfo;
        DECLARE @cmd NVARCHAR(500) = N'DBCC DBINFO(' + QUOTENAME(@db_name) + ') WITH TABLERESULTS';
        INSERT INTO #dbinfo EXEC (@cmd);
        DECLARE @last_clean DATETIME =
            (SELECT TRY_CAST([Value] AS DATETIME)
             FROM #dbinfo WHERE Field = 'dbi_dbccLastKnownGood');
        INSERT INTO #checkdb_results VALUES (@db_name, @last_clean);
    END TRY
    BEGIN CATCH
        INSERT INTO #checkdb_results VALUES (@db_name, NULL);
    END CATCH
    FETCH NEXT FROM db_cursor INTO @db_name;
END
CLOSE db_cursor; DEALLOCATE db_cursor;

DECLARE @checkdb_json NVARCHAR(MAX);
SET @checkdb_json = (
    SELECT
        database_name,
        last_clean_dbcc,
        CASE WHEN last_clean_dbcc IS NULL THEN NULL
             ELSE DATEDIFF(DAY, last_clean_dbcc, GETDATE())
        END AS days_since
    FROM #checkdb_results
    FOR JSON PATH
);

SELECT 972 AS "N",
       'maintenance' AS "Section",
       '_checkdb_last_clean_summary' AS "Key",
       N'Дни с момента последней успешной DBCC CHECKDB по всем базам' AS "Label",
       N'' AS "Display",
       ISNULL(@checkdb_json, N'[]') AS "Value";
GO
