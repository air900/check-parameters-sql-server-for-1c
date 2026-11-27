-- ============================================================================
-- СБОР ДАННЫХ MS SQL Server ПО БАЗЕ 1С
-- ============================================================================
--
-- Запустите скрипт в контексте пользовательской базы, например через sqlcmd -d.
-- Результат: N | Section | Key | Label | Display | Value.
--
-- ============================================================================

SET NOCOUNT ON;

-- Распределение ALLOW_PAGE_LOCKS по индексам.
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
  AND DB_ID() > 4  -- только пользовательские базы
HAVING COUNT(*) > 0;
GO

-- Сводка по статистике текущей базы.
SELECT 410 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'statistics' AS "Section",
       '_stats_summary_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Возраст и изменения статистики базы ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
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
JOIN sys.tables t WITH (NOLOCK) ON s.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND DB_ID() > 4;
GO

-- Статистика с наибольшей долей изменений.
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
  AND OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
  AND sp.rows > 1000
  AND sp.modification_counter > 0.2 * sp.rows
ORDER BY (CAST(sp.modification_counter AS DECIMAL(20,1)) / NULLIF(sp.rows, 0)) DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO

-- ============================================================================
-- ФРАГМЕНТАЦИЯ ИНДЕКСОВ
-- Режим LIMITED собирает данные о фрагментации с минимальным чтением страниц.
-- ============================================================================

-- Сводка по текущей базе.
SELECT 420 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'maintenance' AS "Section",
       '_index_fragmentation_summary_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Фрагментация индексов базы ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       -- ISNULL сохраняет вывод при пустом наборе строк.
       CONVERT(NVARCHAR(20), COUNT(*)) + N' индексов / '
         + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent > 30 THEN 1 ELSE 0 END), 0))
           + N' с фрагментацией более 30% / '
         + CONVERT(NVARCHAR(20), ISNULL(SUM(CASE WHEN ips.avg_fragmentation_in_percent BETWEEN 5 AND 30 THEN 1 ELSE 0 END), 0))
           + N' с фрагментацией от 5 до 30% / максимум '
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
WHERE ips.page_count > 1000
  AND ips.index_id > 0                    -- heap (index_id=0) — нет фрагментации
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
  AND DB_ID() > 4;
GO

-- Индексы с наибольшим произведением размера на долю фрагментации.
SELECT 700 + ROW_NUMBER() OVER (ORDER BY ips.avg_fragmentation_in_percent * ips.page_count DESC) AS "N",
       'runtime' AS "Section",
       '_index_top_fragmented_' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '_'
         + CONVERT(NVARCHAR(10), ips.object_id) + '_'
         + CONVERT(NVARCHAR(10), ips.index_id) AS "Key",
       N'Индекс: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_SCHEMA_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + '.'
         + (OBJECT_NAME(ips.object_id) COLLATE DATABASE_DEFAULT) + ' / ' + (i.name COLLATE DATABASE_DEFAULT) AS "Label",
       N'Фрагментация ' + CONVERT(NVARCHAR(20), CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1))) + N'% / размер '
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
  AND ips.avg_fragmentation_in_percent > 30
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
  AND DB_ID() > 4
ORDER BY ips.avg_fragmentation_in_percent * ips.page_count DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO

-- ============================================================================
-- КРУПНЫЕ ТАБЛИЦЫ БЕЗ СЖАТИЯ
-- sys.dm_db_partition_stats содержит счётчики страниц по разделам.
-- ============================================================================

;WITH sizes AS (
    SELECT object_id,
           SUM(reserved_page_count) AS pages
    FROM sys.dm_db_partition_stats
    GROUP BY object_id
), compression AS (
    -- MAX позволяет определить, включено ли сжатие хотя бы в одном разделе.
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
    WHERE t.is_ms_shipped = 0
      AND s.pages * 8 / 1024 > 10240
      AND c.max_compression = 0                     -- 0 = NONE
)
SELECT 440 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'maintenance' AS "Section",
       '_large_uncompressed_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'Крупные несжатые таблицы (>10 ГБ) в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       -- ISNULL сохраняет вывод при пустом наборе строк.
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
-- ВЫБРАННЫЕ НАСТРОЙКИ БАЗЫ ДАННЫХ
-- Динамический запрос к sys.database_scoped_configurations выполняется
-- в текущей базе на SQL Server 2016 и новее.
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
    AND DB_ID() > 4
BEGIN
    EXEC sp_executesql N'
    SELECT 450 + ROW_NUMBER() OVER (ORDER BY name) AS "N",
           ''instance_config'' AS "Section",
           ''_dsc_'' + LOWER(name COLLATE DATABASE_DEFAULT)
                    + ''_'' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
           N''Настройка "'' + name + N''" для базы '' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
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
-- ПОЛНЫЙ СНИМОК НАСТРОЕК БАЗЫ ДАННЫХ
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
    AND DB_ID() > 4
BEGIN
    EXEC sp_executesql N'
    DECLARE @options NVARCHAR(MAX);
    SET @options = STUFF((
        SELECT '',{"name":"'' + name + ''","value":''
                + CONVERT(NVARCHAR(MAX), [value]) + ''}'' AS [text()]
        FROM sys.database_scoped_configurations
        FOR XML PATH('''')
    ), 1, 1, '''');
    SET @options = N''['' + REPLACE(REPLACE(REPLACE(@options COLLATE Latin1_General_100_BIN2,
        N''&lt;'', N''<''), N''&gt;'', N''>''), N''&amp;'', N''&'') + N'']'';

    SELECT 455 AS "N",
           ''instance_config'' AS "Section",
           ''_dsc_all_'' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
           N''Настройки уровня базы ''
                + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
           @options AS "Display",
           N''{"db":"'' + (DB_NAME() COLLATE DATABASE_DEFAULT)
                + N''","options":'' + @options + N''}'' AS "Value"';
END
GO

-- ============================================================================
-- СОСТОЯНИЕ QUERY STORE (SQL Server 2016 и новее)
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
                WHEN 1 THEN N''READ_ONLY (только чтение)''
                WHEN 2 THEN N''READ_WRITE (чтение и запись)''
                WHEN 3 THEN N''ERROR''
           END
           + N'' / режим сбора запросов '' + qso.query_capture_mode_desc
           + N'' / лимит '' + CONVERT(NVARCHAR(20), qso.max_storage_size_mb) + N'' MB'' AS "Display",
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
-- СОСТОЯНИЕ TRUSTWORTHY
-- ============================================================================

SELECT 480 + ROW_NUMBER() OVER (ORDER BY DB_ID()) AS "N",
       'security' AS "Section",
       '_trustworthy_' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Key",
       N'TRUSTWORTHY в БД: ' + (DB_NAME() COLLATE DATABASE_DEFAULT) AS "Label",
       CASE WHEN d.is_trustworthy_on = 1 THEN N'включено' ELSE N'выключено' END AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"db":"' + (DB_NAME() COLLATE DATABASE_DEFAULT) + '"'
         + ',"trustworthy_on":' + CONVERT(NVARCHAR(1), d.is_trustworthy_on)
         + '}'
       ) AS "Value"
FROM sys.databases d
WHERE d.database_id = DB_ID() AND d.database_id > 4;
GO

-- ============================================================================
-- СОСТОЯНИЕ ACCELERATED DATABASE RECOVERY (SQL Server 2019 и новее)
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
-- СВОДКА ПО ТАБЛИЦАМ 1С
-- ============================================================================

;WITH categorized AS (
    SELECT t.object_id, t.name,
           CASE
                WHEN t.name LIKE '%\_VT%' ESCAPE '\' THEN 'tabular_section'

                WHEN t.name LIKE '\_Reference%' ESCAPE '\'                                THEN 'reference'
                WHEN t.name LIKE '\_DocumentJournal%' ESCAPE '\'                          THEN 'document_journal'
                WHEN t.name LIKE '\_Document%' ESCAPE '\'                                 THEN 'document'

                WHEN t.name LIKE '\_AccumRgT%' ESCAPE '\'                                 THEN 'accumreg_totals'
                WHEN t.name LIKE '\_AccumRgOpt%' ESCAPE '\'                               THEN 'accumreg_totals'
                WHEN t.name LIKE '\_AccumRgChngR%' ESCAPE '\'                             THEN 'accumreg_movements'
                WHEN t.name LIKE '\_AccumRgDl%' ESCAPE '\'                                THEN 'accumreg_movements'
                WHEN t.name LIKE '\_AccumRg%' ESCAPE '\'                                  THEN 'accumreg_movements'

                WHEN t.name LIKE '\_InfoRgChngR%' ESCAPE '\'                              THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRgSL%' ESCAPE '\'                                 THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRgSF%' ESCAPE '\'                                 THEN 'inforeg'
                WHEN t.name LIKE '\_InfoRg%' ESCAPE '\'                                   THEN 'inforeg'

                WHEN t.name LIKE '\_AccRgChngR%' ESCAPE '\'                               THEN 'accreg'
                WHEN t.name LIKE '\_AccRgED%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRgAT%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRgCT%' ESCAPE '\'                                  THEN 'accreg'
                WHEN t.name LIKE '\_AccRg%' ESCAPE '\'                                    THEN 'accreg'

                WHEN t.name LIKE '\_CalcRgChngR%' ESCAPE '\'                              THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgActPer%' ESCAPE '\'                             THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgRecalc%' ESCAPE '\'                             THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRgDR%' ESCAPE '\'                                 THEN 'calcreg'
                WHEN t.name LIKE '\_CalcRg%' ESCAPE '\'                                   THEN 'calcreg'

                WHEN t.name LIKE '\_Chrc%' ESCAPE '\'                                     THEN 'chrc'
                WHEN t.name LIKE '\_Acc%' ESCAPE '\'                                      THEN 'accchrt'
                WHEN t.name LIKE '\_Enum%' ESCAPE '\'                                     THEN 'enum'
                WHEN t.name LIKE '\_Const%' ESCAPE '\'                                    THEN 'const'

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
-- Сводки по экземпляру.
-- ============================================================================

DECLARE @db_health TABLE (
    summary_number INT NOT NULL,
    database_name SYSNAME NULL,
    is_encrypted BIT NULL,
    encryption_state INT NULL,
    certificate_expiry_days INT NULL,
    suspect_page_count INT NULL,
    last_clean_dbcc DATETIME NULL,
    json_name NVARCHAR(768) NULL
);

-- ── TDE state per database ────────────────────────────────────────────────
-- VIEW SERVER STATE требуется для sys.dm_database_encryption_keys.
-- Сертификат TDE хранится в master, даже когда сбор запущен из пользовательской БД.
BEGIN TRY
    INSERT INTO @db_health (summary_number, database_name, is_encrypted,
                            encryption_state, certificate_expiry_days)
    SELECT 970, d.name, d.is_encrypted, ek.encryption_state,
           DATEDIFF(DAY, GETDATE(), c.expiry_date)
    FROM sys.databases d
    LEFT JOIN sys.dm_database_encryption_keys ek ON ek.database_id = d.database_id
    LEFT JOIN master.sys.certificates c ON c.thumbprint = ek.encryptor_thumbprint
    WHERE d.database_id > 4;
END TRY
BEGIN CATCH
    DELETE FROM @db_health WHERE summary_number = 970;
END CATCH;

-- ── msdb.dbo.suspect_pages — count per DB ─────────────────────────────────
INSERT INTO @db_health (summary_number, database_name, suspect_page_count)
SELECT 971, DB_NAME(database_id), COUNT(*)
FROM msdb.dbo.suspect_pages
GROUP BY database_id;

-- ── DBCC DBINFO — last clean DBCC CHECKDB per DB ──────────────────────────
-- Поле dbi_dbccLastKnownGood доступно до появления свойства LastGoodCheckDbTime.
IF OBJECT_ID('tempdb..#dbinfo') IS NOT NULL DROP TABLE #dbinfo;
CREATE TABLE #dbinfo (
    ParentObject NVARCHAR(255),
    [Object]     NVARCHAR(255),
    Field        NVARCHAR(255),
    [Value]      NVARCHAR(MAX)
);
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
        INSERT INTO @db_health (summary_number, database_name, last_clean_dbcc)
        VALUES (972, @db_name, @last_clean);
    END TRY
    BEGIN CATCH
        INSERT INTO @db_health (summary_number, database_name)
        VALUES (972, @db_name);
    END CATCH
    FETCH NEXT FROM db_cursor INTO @db_name;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;
DROP TABLE #dbinfo;

-- Экранируем имена для JSON до сборки через FOR XML PATH (SQL Server 2014).
UPDATE @db_health
SET json_name = REPLACE(REPLACE(REPLACE(REPLACE(database_name COLLATE Latin1_General_100_BIN2,
    N'\', N'\\'), N'"', N'\"'), NCHAR(65534), N'\ufffe'), NCHAR(65535), N'\uffff');

DECLARE @code INT = 1;
WHILE @code < 32
BEGIN
    DECLARE @escaped NVARCHAR(6) = N'\u' + CONVERT(CHAR(4), CONVERT(BINARY(2), @code), 2);
    UPDATE @db_health
    SET json_name = REPLACE(json_name COLLATE Latin1_General_100_BIN2, NCHAR(@code), @escaped)
    WHERE CHARINDEX(NCHAR(@code), json_name COLLATE Latin1_General_100_BIN2) > 0;
    SET @code += 1;
END;

;WITH objects AS (
    SELECT summary_number, database_name,
           CONCAT(N',{', STUFF(CONCAT(
               CASE WHEN json_name IS NOT NULL THEN N',"database_name":"' + json_name + N'"' END,
               CASE is_encrypted WHEN 1 THEN N',"is_encrypted":true'
                                 WHEN 0 THEN N',"is_encrypted":false' END,
               CASE WHEN encryption_state IS NOT NULL
                    THEN CONCAT(N',"encryption_state":', encryption_state) END,
               CASE WHEN certificate_expiry_days IS NOT NULL
                    THEN CONCAT(N',"certificate_expiry_days":', certificate_expiry_days) END,
               CASE WHEN suspect_page_count IS NOT NULL
                    THEN CONCAT(N',"suspect_page_count":', suspect_page_count) END,
               CASE WHEN last_clean_dbcc IS NOT NULL
                    THEN CONCAT(N',"last_clean_dbcc":"', CONVERT(NVARCHAR(23), last_clean_dbcc, 126),
                         N'","days_since":', DATEDIFF(DAY, last_clean_dbcc, GETDATE())) END
           ), 1, 1, N''), N'}') AS json_object
    FROM @db_health
)
SELECT s.number AS "N",
       s.section AS "Section",
       s.[key] AS "Key",
       s.label AS "Label",
       N'' AS "Display",
       N'[' + ISNULL(STUFF(REPLACE(REPLACE(REPLACE(x.xml_text COLLATE Latin1_General_100_BIN2,
           N'&lt;', N'<'), N'&gt;', N'>'), N'&amp;', N'&'), 1, 1, N''), N'') + N']' AS "Value"
FROM (VALUES
    (970, 'security', '_tde_state_summary', N'Состояние TDE по всем базам'),
    (971, 'maintenance', '_suspect_pages_summary', N'Записи о повреждённых страницах по всем базам'),
    (972, 'maintenance', '_checkdb_last_clean_summary', N'Дни с момента последней успешной DBCC CHECKDB по всем базам')
) AS s(number, section, [key], label)
CROSS APPLY (
    SELECT (
        SELECT o.json_object AS [text()]
        FROM objects o
        WHERE o.summary_number = s.number
        ORDER BY o.database_name
        FOR XML PATH('')
    ) AS xml_text
) AS x
ORDER BY s.number;
GO
