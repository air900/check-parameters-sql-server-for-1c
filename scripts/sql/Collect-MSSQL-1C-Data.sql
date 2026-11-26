-- ============================================================================
-- СБОР ДАННЫХ MS SQL Server ДЛЯ РАБОТЫ С 1С:ПРЕДПРИЯТИЕ
-- ============================================================================
--
-- Запуск: выполните скрипт целиком в SSMS.
-- Сбор использует системные представления и временные таблицы сеанса.
-- Результат: N | Section | Key | Label | Display | Value.
-- Display содержит значение для чтения, Value — значение для обработки.
--
-- Контакты:
--   audit-reshenie.ru | info@audit-reshenie.ru
--
-- ============================================================================

SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;
SET ARITHABORT OFF;

-- INSERT EXEC сохраняет результат DBCC TRACESTATUS во временную таблицу #tf.

IF OBJECT_ID('tempdb..#tf') IS NULL
BEGIN
  CREATE TABLE #tf (TraceFlag INT, Status INT, [Global] INT, [Session] INT);
  BEGIN TRY
    INSERT INTO #tf EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
  END TRY
  BEGIN CATCH
    -- Если DBCC TRACESTATUS недоступен, таблица #tf остаётся пустой.
  END CATCH
END;

-- Столбцы LPIM и IFI зависят от сборки SQL Server. Динамический запрос
-- компилируется только при наличии нужного столбца.
DECLARE @sql_memory_model INT, @ifi_enabled NVARCHAR(1);

IF EXISTS (SELECT 1 FROM sys.all_columns
           WHERE object_id = OBJECT_ID(N'sys.dm_os_sys_info') AND name = N'sql_memory_model')
    EXEC sys.sp_executesql N'SELECT @model = sql_memory_model FROM sys.dm_os_sys_info',
        N'@model INT OUTPUT', @model = @sql_memory_model OUTPUT;

IF EXISTS (SELECT 1 FROM sys.all_columns
           WHERE object_id = OBJECT_ID(N'sys.dm_server_services') AND name = N'instant_file_initialization_enabled')
    EXEC sys.sp_executesql N'
        SELECT @ifi = MAX(instant_file_initialization_enabled)
        FROM sys.dm_server_services
        WHERE (servicename COLLATE DATABASE_DEFAULT) LIKE ''SQL Server%''
          AND (servicename COLLATE DATABASE_DEFAULT) NOT LIKE ''SQL Server Agent%''',
        N'@ifi NVARCHAR(1) OUTPUT', @ifi = @ifi_enabled OUTPUT;

-- При локальном подключении через shared memory собственный TCP-порт не задан.
-- Используем порт слушателя только при однозначном результате.
DECLARE @tcp_port INT = CONVERT(INT, CONNECTIONPROPERTY('local_tcp_port'));
IF @tcp_port IS NULL AND OBJECT_ID(N'sys.dm_tcp_listener_states') IS NOT NULL
BEGIN TRY
    EXEC sys.sp_executesql N'
        SELECT @port = CASE WHEN MIN(port) = MAX(port) THEN MIN(port) END
        FROM sys.dm_tcp_listener_states
        WHERE type_desc = N''TSQL'' AND state_desc = N''ONLINE'' AND port > 0',
        N'@port INT OUTPUT', @port = @tcp_port OUTPUT;
END TRY
BEGIN CATCH
    SET @tcp_port = NULL;
END CATCH;

;WITH all_data AS (

-- ============================================================================
-- ИНФОРМАЦИЯ О СЕРВЕРЕ
-- ============================================================================

SELECT 1 AS "N", 'server_info' AS "Section",
    '_info_sql_version' AS "Key",
    N'Версия SQL Server' AS "Label",
    CONVERT(NVARCHAR(200), SERVERPROPERTY('ProductVersion'))
        + ' / ' + CONVERT(NVARCHAR(200), SERVERPROPERTY('ProductLevel'))
        + ' / ' + CONVERT(NVARCHAR(200), SERVERPROPERTY('Edition')) AS "Display",
    CONVERT(NVARCHAR(200), SERVERPROPERTY('ProductVersion')) AS "Value"

UNION ALL
SELECT 2, 'server_info',
    '_info_sql_major',
    N'Мажорная версия SQL Server',
    CONVERT(NVARCHAR(50), SERVERPROPERTY('ProductMajorVersion'))
      + ' (' +
      CASE CONVERT(INT, SERVERPROPERTY('ProductMajorVersion'))
        WHEN 12 THEN '2014'
        WHEN 13 THEN '2016' WHEN 14 THEN '2017'
        WHEN 15 THEN '2019' WHEN 16 THEN '2022'
        ELSE 'unknown'
      END + ')',
    CONVERT(NVARCHAR(50), SERVERPROPERTY('ProductMajorVersion'))

UNION ALL
SELECT 3, 'server_info',
    '_info_instance',
    N'Имя экземпляра',
    (@@SERVERNAME COLLATE DATABASE_DEFAULT) + ISNULL(' \ ' + CONVERT(NVARCHAR(200), SERVERPROPERTY('InstanceName')), ''),
    (@@SERVERNAME COLLATE DATABASE_DEFAULT)

UNION ALL
SELECT 4, 'server_info',
    '_info_hostname',
    N'Имя хоста',
    CONVERT(NVARCHAR(200), SERVERPROPERTY('MachineName')),
    CONVERT(NVARCHAR(200), SERVERPROPERTY('MachineName'))

UNION ALL
SELECT 5, 'server_info',
    '_info_collation',
    N'Кодировка сервера',
    CONVERT(NVARCHAR(200), SERVERPROPERTY('Collation')),
    CONVERT(NVARCHAR(200), SERVERPROPERTY('Collation'))

UNION ALL
SELECT 6, 'server_info',
    '_info_cpu_count',
    N'Логических CPU',
    CONVERT(NVARCHAR(20), cpu_count) + ' (' + CONVERT(NVARCHAR(20), scheduler_count) + ' schedulers)',
    CONVERT(NVARCHAR(20), cpu_count)
FROM sys.dm_os_sys_info

UNION ALL
SELECT 7, 'server_info',
    '_info_ram_total',
    N'Физическая память (RAM)',
    CONVERT(NVARCHAR(20), physical_memory_kb / 1024 / 1024) + ' GB ('
        + CONVERT(NVARCHAR(20), physical_memory_kb / 1024) + ' MB)',
    CONVERT(NVARCHAR(50), physical_memory_kb * 1024)  -- bytes
FROM sys.dm_os_sys_info

UNION ALL
SELECT 8, 'server_info',
    '_info_uptime',
    N'Время работы',
    CONVERT(NVARCHAR(50),
        DATEDIFF(DAY, sqlserver_start_time, GETDATE())) + N' дн. '
        + CONVERT(NVARCHAR(50),
            DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) % 24) + N' ч.',
    CONVERT(NVARCHAR(50),
        DATEDIFF(SECOND, sqlserver_start_time, GETDATE()))
FROM sys.dm_os_sys_info

UNION ALL
SELECT 9, 'server_info',
    '_info_virtualization',
    N'Виртуализация',
    CONVERT(NVARCHAR(50), virtual_machine_type_desc),
    CONVERT(NVARCHAR(50), virtual_machine_type_desc)
FROM sys.dm_os_sys_info

UNION ALL
SELECT 10, 'server_info',
    '_info_check_date',
    N'Дата проверки',
    CONVERT(NVARCHAR(20), GETDATE(), 120),
    CONVERT(NVARCHAR(30), GETDATE(), 126)

UNION ALL
SELECT 11, 'server_info', '_info_tcp_port', N'TCP-порт SQL Server',
    CONVERT(NVARCHAR(10), @tcp_port), CONVERT(NVARCHAR(10), @tcp_port)
WHERE @tcp_port BETWEEN 1 AND 65535

UNION ALL

-- ============================================================================
-- ПАМЯТЬ
-- ============================================================================

SELECT 22, 'memory',
    'lpim_enabled',
    'Lock Pages in Memory (LPIM)',
    CASE @sql_memory_model
      WHEN 1 THEN N'CONVENTIONAL (LPIM выключен)'
      WHEN 2 THEN N'LOCK_PAGES (LPIM активен)'
      WHEN 3 THEN N'LARGE_PAGES (LPIM + Large Pages)'
      ELSE N'нет данных'
    END,
    CASE
      WHEN @sql_memory_model IN (2, 3) THEN 'true'
      WHEN @sql_memory_model = 1 THEN 'false'
      ELSE 'unknown'
    END

UNION ALL
SELECT 23, 'memory',
    'committed_target_mb',
    N'Целевая выделенная память',
    CONVERT(NVARCHAR(20), committed_target_kb / 1024) + ' MB',
    CONVERT(NVARCHAR(50), committed_target_kb * 1024)  -- bytes
FROM sys.dm_os_sys_info

UNION ALL

-- ============================================================================
-- ПАРАЛЛЕЛИЗМ
-- ============================================================================

-- ============================================================================
-- TempDB
-- ============================================================================

SELECT 40, 'tempdb',
    'tempdb_data_files_count',
    N'Количество data-файлов tempdb',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.master_files
WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'

UNION ALL
SELECT 41, 'tempdb',
    'tempdb_total_data_mb',
    N'Суммарный размер data-файлов tempdb',
    CONVERT(NVARCHAR(20), SUM(size) * 8 / 1024) + ' MB',
    CONVERT(NVARCHAR(50), SUM(CAST(size AS BIGINT)) * 8192)  -- bytes
FROM sys.master_files
WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'

UNION ALL
SELECT 42, 'tempdb',
    'tempdb_log_files_count',
    N'Количество log-файлов tempdb',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.master_files
WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'LOG'

UNION ALL
SELECT 43, 'tempdb',
    'tempdb_files_equal_size',
    N'Все data-файлы tempdb одного размера',
    CASE WHEN COUNT(DISTINCT size) <= 1 THEN N'да' ELSE N'нет (' + CONVERT(NVARCHAR(20), COUNT(DISTINCT size)) + N' разных)' END,
    CASE WHEN COUNT(DISTINCT size) <= 1 THEN 'true' ELSE 'false' END
FROM sys.master_files
WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'

UNION ALL
SELECT 44, 'tempdb',
    'tempdb_growth_in_mb',
    N'Авторасширение tempdb в МБ (не процентах)',
    CASE
      WHEN MAX(CAST(is_percent_growth AS INT)) = 0 THEN N'да (фикс. МБ)'
      ELSE N'нет (хотя бы один файл — в %)'
    END,
    CASE WHEN MAX(CAST(is_percent_growth AS INT)) = 0 THEN 'true' ELSE 'false' END
FROM sys.master_files
WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'

UNION ALL
SELECT 45, 'tempdb',
    'tempdb_metadata_memory_optimized',
    'Memory-optimized TempDB Metadata (SQL 2019+)',
    CASE
      WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 15
      THEN N'не поддерживается (SQL < 2019)'
      WHEN EXISTS (SELECT 1 FROM sys.configurations
                   WHERE (name COLLATE DATABASE_DEFAULT) = 'tempdb metadata memory-optimized'
                     AND CAST(value_in_use AS INT) = 1)
      THEN N'включено'
      ELSE N'выключено'
    END,
    CASE
      WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 15 THEN 'n/a'
      WHEN EXISTS (SELECT 1 FROM sys.configurations
                   WHERE (name COLLATE DATABASE_DEFAULT) = 'tempdb metadata memory-optimized'
                     AND CAST(value_in_use AS INT) = 1) THEN 'true'
      ELSE 'false'
    END

UNION ALL
-- ============================================================================
-- МОДЕЛЬ ВОССТАНОВЛЕНИЯ И ЖУРНАЛ ТРАНЗАКЦИЙ (агрегаты)
-- ============================================================================

SELECT 50, 'recovery',
    'auto_shrink_enabled_count',
    N'Баз с включённым auto_shrink',
    CONVERT(NVARCHAR(20), COUNT(*)) + N' из '
      + CONVERT(NVARCHAR(20), (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND is_auto_shrink_on = 1

UNION ALL
SELECT 51, 'recovery',
    'recovery_full_count',
    N'Баз в FULL recovery model',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND recovery_model = 1  -- FULL

UNION ALL
SELECT 52, 'recovery',
    'percent_growth_files_count',
    N'Файлов БД с процентным авторасширением',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.master_files
WHERE database_id > 4 AND is_percent_growth = 1

UNION ALL
SELECT 53, 'recovery',
    'model_initial_size_mb',
    N'Начальный размер data-файлов БД model (шаблон новых БД), MB',
    CONVERT(NVARCHAR(20), ISNULL(SUM(CAST(size AS BIGINT) * 8 / 1024), 0)) + ' MB',
    CONVERT(NVARCHAR(20), ISNULL(SUM(CAST(size AS BIGINT) * 8 / 1024), 0))
-- База model служит шаблоном для новых баз данных.
FROM model.sys.database_files
WHERE (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'

UNION ALL
-- sys.master_files включает файлы пользовательских баз в состоянии OFFLINE.
SELECT 54, 'recovery',
    'largest_user_db_size_gb',
    N'Размер крупнейшей пользовательской БД',
    CASE WHEN COALESCE(MAX(db_size_mb), 0) >= 1024
         THEN CONVERT(NVARCHAR(20), CAST(MAX(db_size_mb) / 1024.0 AS DECIMAL(15, 1))) + ' GB'
         ELSE CONVERT(NVARCHAR(20), COALESCE(MAX(db_size_mb), 0)) + ' MB'
    END,
    -- Размер в ГБ с тремя знаками после запятой.
    CONVERT(NVARCHAR(20), CAST(COALESCE(MAX(db_size_mb), 0) / 1024.0 AS DECIMAL(15, 3)))
FROM (
    SELECT database_id, SUM(CAST(size AS BIGINT)) * 8 / 1024 AS db_size_mb
    FROM sys.master_files
    WHERE database_id > 4
    GROUP BY database_id
) x

UNION ALL
SELECT 55, 'recovery',
    'total_user_db_size_gb',
    N'Суммарный размер пользовательских БД',
    CASE WHEN COALESCE(SUM(db_size_mb), 0) >= 1024
         THEN CONVERT(NVARCHAR(20), CAST(SUM(db_size_mb) / 1024.0 AS DECIMAL(15, 1))) + ' GB'
         ELSE CONVERT(NVARCHAR(20), COALESCE(SUM(db_size_mb), 0)) + ' MB'
    END,
    CONVERT(NVARCHAR(20), CAST(COALESCE(SUM(db_size_mb), 0) / 1024.0 AS DECIMAL(15, 3)))
FROM (
    SELECT database_id, SUM(CAST(size AS BIGINT)) * 8 / 1024 AS db_size_mb
    FROM sys.master_files
    WHERE database_id > 4
    GROUP BY database_id
) x

UNION ALL
-- Число пользовательских баз без READ_COMMITTED_SNAPSHOT.
SELECT 56, 'recovery',
    'rcsi_disabled_db_count',
    N'Баз 1С без снимочного чтения (READ_COMMITTED_SNAPSHOT OFF)',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND is_read_committed_snapshot_on = 0

UNION ALL
-- ============================================================================
-- СТАТИСТИКА И ИНДЕКСЫ (агрегаты)
-- ============================================================================

SELECT 60, 'statistics',
    'auto_update_stats_off_count',
    N'Баз с выключенным auto update statistics',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND is_auto_update_stats_on = 0

UNION ALL
SELECT 61, 'statistics',
    'auto_update_stats_async_off_count',
    N'Баз с выключенным async update statistics',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND is_auto_update_stats_async_on = 0

UNION ALL
SELECT 62, 'statistics',
    'page_verify_not_checksum_count',
    N'Баз без CHECKSUM page_verify',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.databases
WHERE database_id > 4 AND (page_verify_option_desc COLLATE DATABASE_DEFAULT) <> 'CHECKSUM'

UNION ALL

-- ============================================================================
-- АУТЕНТИФИКАЦИЯ И ПРАВА
-- ============================================================================

SELECT 70, 'auth',
    'authentication_mode',
    N'Режим аутентификации',
    CASE CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT)
      WHEN 1 THEN 'Windows-only'
      ELSE 'Mixed Mode (SQL + Windows)'
    END,
    CASE CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT)
      WHEN 1 THEN 'windows_only'
      ELSE 'mixed_mode'
    END

UNION ALL
SELECT 71, 'auth',
    'sa_disabled',
    N'Учётка sa отключена',
    CASE WHEN is_disabled = 1 THEN N'да' ELSE N'нет' END,
    CASE WHEN is_disabled = 1 THEN 'true' ELSE 'false' END
FROM sys.server_principals WHERE (name COLLATE DATABASE_DEFAULT) = 'sa'

UNION ALL
SELECT 72, 'auth',
    'sa_password_age_days',
    N'Возраст пароля sa (дней)',
    CONVERT(NVARCHAR(20),
      ISNULL(DATEDIFF(DAY, CAST(LOGINPROPERTY('sa', 'PasswordLastSetTime') AS DATETIME), GETDATE()), -1)),
    CONVERT(NVARCHAR(20),
      ISNULL(DATEDIFF(DAY, CAST(LOGINPROPERTY('sa', 'PasswordLastSetTime') AS DATETIME), GETDATE()), -1))

UNION ALL
SELECT 73, 'auth',
    'ifi_enabled',
    'Database Instant File Initialization (IFI)',
    CASE @ifi_enabled
      WHEN 'Y' THEN N'включено'
      WHEN 'N' THEN N'выключено'
      ELSE N'нет данных'
    END,
    CASE @ifi_enabled
      WHEN 'Y' THEN 'true'
      WHEN 'N' THEN 'false'
      ELSE 'unknown'
    END

UNION ALL
SELECT 75, 'auth',
    'dbcreator_login_count',
    N'SQL/Windows-логинов с ролью dbcreator (не sa, не dis abled)',
    CONVERT(NVARCHAR(20), COUNT(DISTINCT sp.principal_id)),
    CONVERT(NVARCHAR(20), COUNT(DISTINCT sp.principal_id))
FROM sys.server_principals sp
JOIN sys.server_role_members srm ON srm.member_principal_id = sp.principal_id
JOIN sys.server_principals sr ON sr.principal_id = srm.role_principal_id
WHERE (sr.name COLLATE DATABASE_DEFAULT) = 'dbcreator'
  AND sp.is_disabled = 0
  AND sp.type IN ('S','U')      -- SQL login или Windows user
  AND (sp.name COLLATE DATABASE_DEFAULT) NOT LIKE '##%'    -- системные internal-логины
  AND (sp.name COLLATE DATABASE_DEFAULT) <> 'sa'           -- sa уже sysadmin, не считаем

UNION ALL

-- ============================================================================
-- ФЛАГИ ТРАССИРОВКИ
-- ============================================================================

SELECT 80, 'traceflags',
    'tf_7471_active',
    'TF 7471 (parallel UPDATE STATISTICS)',
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 7471 AND [Global] = 1) THEN N'включён' ELSE N'выключен' END,
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 7471 AND [Global] = 1) THEN 'true' ELSE 'false' END
FROM (SELECT 1 AS dummy) d

UNION ALL
SELECT 81, 'traceflags',
    'tf_3226_active',
    'TF 3226 (suppress backup messages)',
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 3226 AND [Global] = 1) THEN N'включён' ELSE N'выключен' END,
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 3226 AND [Global] = 1) THEN 'true' ELSE 'false' END
FROM (SELECT 1 AS dummy) d

UNION ALL
SELECT 82, 'traceflags',
    'tf_4199_active_global',
    N'TF 4199 (Query Optimizer Hotfixes — глобально)',
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 4199 AND [Global] = 1) THEN N'включён глобально'
         ELSE N'не глобально (см. database-scoped)' END,
    CASE WHEN EXISTS (SELECT 1 FROM #tf WHERE TraceFlag = 4199 AND [Global] = 1) THEN 'true' ELSE 'false' END
FROM (SELECT 1 AS dummy) d

UNION ALL

-- ============================================================================
-- КОНФИГУРАЦИЯ ЭКЗЕМПЛЯРА
-- ============================================================================

SELECT 90, 'instance_config',
    'collation_mismatched_db_count',
    N'Баз с несовпадающим collation',
    CONVERT(NVARCHAR(20),
      (SELECT COUNT(*) FROM sys.databases
       WHERE database_id > 4
         AND (collation_name COLLATE DATABASE_DEFAULT) <> CAST(SERVERPROPERTY('Collation') AS sysname))),
    CONVERT(NVARCHAR(20),
      (SELECT COUNT(*) FROM sys.databases
       WHERE database_id > 4
         AND (collation_name COLLATE DATABASE_DEFAULT) <> CAST(SERVERPROPERTY('Collation') AS sysname)))

UNION ALL
SELECT 91, 'instance_config',
    'compat_outdated_db_count',
    N'Баз с устаревшим compatibility_level',
    CONVERT(NVARCHAR(20),
      (SELECT COUNT(*) FROM sys.databases
       WHERE database_id > 4
         AND compatibility_level < CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) * 10)),
    CONVERT(NVARCHAR(20),
      (SELECT COUNT(*) FROM sys.databases
       WHERE database_id > 4
         AND compatibility_level < CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) * 10))

UNION ALL
-- ============================================================================
-- I/O И ДИСКОВАЯ ПОДСИСТЕМА (агрегаты)
-- ============================================================================

SELECT 100, 'io',
    'data_log_same_volume',
    N'Data и Log на одном томе',
    CASE WHEN COUNT(DISTINCT LEFT(physical_name, 3))
              = COUNT(DISTINCT CASE WHEN type_desc IN ('ROWS','LOG') THEN type_desc END)
         THEN N'разнесены'
         ELSE N'есть совмещения' END,
    CASE WHEN COUNT(DISTINCT LEFT(physical_name, 3))
              = COUNT(DISTINCT CASE WHEN type_desc IN ('ROWS','LOG') THEN type_desc END)
         THEN 'true' ELSE 'false' END
FROM sys.master_files WHERE database_id > 4

UNION ALL
SELECT 101, 'io',
    'tempdb_on_separate_volume',
    N'TempDB на отдельном томе',
    CASE WHEN
      (SELECT TOP 1 LEFT(physical_name, 3) FROM sys.master_files
       WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS') NOT IN
      (SELECT DISTINCT LEFT(physical_name, 3) FROM sys.master_files
       WHERE database_id > 4 AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS')
      THEN N'да' ELSE N'нет (общий том с пользовательскими БД)' END,
    CASE WHEN
      (SELECT TOP 1 LEFT(physical_name, 3) FROM sys.master_files
       WHERE database_id = DB_ID('tempdb') AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS') NOT IN
      (SELECT DISTINCT LEFT(physical_name, 3) FROM sys.master_files
       WHERE database_id > 4 AND (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS')
      THEN 'true' ELSE 'false' END

UNION ALL

-- ============================================================================
-- РЕГЛАМЕНТНЫЕ ОПЕРАЦИИ (агрегаты)
-- ============================================================================

SELECT 110, 'maintenance',
    'shrink_in_jobs',
    N'Найдены задания SHRINK в Job Agent',
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobsteps
      WHERE command LIKE '%SHRINKDATABASE%'
         OR command LIKE '%SHRINKFILE%'
         OR command LIKE '%DBCC SHRINK%'
    ) THEN N'да (антипаттерн)' ELSE N'нет' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobsteps
      WHERE command LIKE '%SHRINKDATABASE%'
         OR command LIKE '%SHRINKFILE%'
         OR command LIKE '%DBCC SHRINK%'
    ) THEN 'true' ELSE 'false' END

UNION ALL
SELECT 111, 'maintenance',
    'freeproccache_in_jobs',
    N'Найден глобальный DBCC FREEPROCCACHE в Job Agent',
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobsteps
      WHERE command LIKE '%FREEPROCCACHE%'
        AND command NOT LIKE '%FREEPROCCACHE(%'  -- исключаем targeted FREEPROCCACHE(plan_handle)
    ) THEN N'да (антипаттерн для SQL 2014+)' ELSE N'нет' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobsteps
      WHERE command LIKE '%FREEPROCCACHE%'
        AND command NOT LIKE '%FREEPROCCACHE(%'
    ) THEN 'true' ELSE 'false' END

UNION ALL
SELECT 112, 'maintenance',
    'ola_hallengren_installed',
    N'Ola Hallengren MaintenanceSolution установлен',
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobs
      WHERE (name COLLATE DATABASE_DEFAULT) LIKE '%IndexOptimize%'
         OR (name COLLATE DATABASE_DEFAULT) LIKE '%DatabaseBackup%'
         OR (name COLLATE DATABASE_DEFAULT) LIKE '%DatabaseIntegrityCheck%'
    ) THEN N'да' ELSE N'нет' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM msdb.dbo.sysjobs
      WHERE (name COLLATE DATABASE_DEFAULT) LIKE '%IndexOptimize%'
         OR (name COLLATE DATABASE_DEFAULT) LIKE '%DatabaseBackup%'
         OR (name COLLATE DATABASE_DEFAULT) LIKE '%DatabaseIntegrityCheck%'
    ) THEN 'true' ELSE 'false' END

UNION ALL
SELECT 113, 'maintenance',
    'last_full_backup_hours',
    N'Часов с последнего full-backup (max по всем БД)',
    ISNULL(CONVERT(NVARCHAR(20),
        DATEDIFF(HOUR, MAX(backup_finish_date), GETDATE())), N'нет ни одного'),
    -- При отсутствии резервных копий Display содержит соответствующее сообщение.
    ISNULL(CONVERT(NVARCHAR(20),
        DATEDIFF(HOUR, MAX(backup_finish_date), GETDATE())), '999999')
FROM msdb.dbo.backupset
WHERE (type COLLATE DATABASE_DEFAULT) = 'D'

UNION ALL
SELECT 114, 'maintenance',
    'update_statistics_job_exists',
    N'Регламентное задание обновления статистики',
    CASE WHEN
      -- Команды T-SQL
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%UPDATE STATISTICS%'
            OR st.command LIKE '%sp_updatestats%'
            OR st.command LIKE '%@UpdateStatistics%'
            OR st.command LIKE '%IndexOptimize%')
      )
      -- Пакеты SSIS
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Update Statistics Task%'
            OR st.command LIKE '%Обновление статистики%'
            OR st.command LIKE '%subplan%')
      )
      -- Подпланы обслуживания
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Statist%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%статист%')
      )
      -- Команды PowerShell
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND (st.command LIKE '%Invoke-DbaIndexOptimize%'
            OR st.command LIKE '%Update-DbaStat%'
            OR st.command LIKE '%sp_updatestats%')
      )
    THEN N'есть' ELSE N'нет' END,
    CASE WHEN
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%UPDATE STATISTICS%'
            OR st.command LIKE '%sp_updatestats%'
            OR st.command LIKE '%@UpdateStatistics%'
            OR st.command LIKE '%IndexOptimize%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Update Statistics Task%'
            OR st.command LIKE '%Обновление статистики%'
            OR st.command LIKE '%subplan%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Statist%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%статист%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND (st.command LIKE '%Invoke-DbaIndexOptimize%'
            OR st.command LIKE '%Update-DbaStat%'
            OR st.command LIKE '%sp_updatestats%')
      )
    THEN 'true' ELSE 'false' END

UNION ALL
SELECT 115, 'maintenance',
    'index_maintenance_job_exists',
    N'Регламентное задание обслуживания индексов',
    CASE WHEN
      -- Команды T-SQL
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%ALTER INDEX%REORGANIZE%'
            OR st.command LIKE '%ALTER INDEX%REBUILD%'
            OR st.command LIKE '%IndexOptimize%')
      )
      -- Пакеты SSIS
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Reorganize Index Task%'
            OR st.command LIKE '%Rebuild Index Task%'
            OR st.command LIKE '%Реорганизация индексов%'
            OR st.command LIKE '%Перестройка индексов%'
            OR st.command LIKE '%subplan%')
      )
      -- Подпланы обслуживания
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Index%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%индекс%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Reorg%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Rebuild%')
      )
      -- Команды PowerShell
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND (st.command LIKE '%Invoke-DbaIndexOptimize%'
            OR st.command LIKE '%Optimize-DbaIndex%')
      )
    THEN N'есть' ELSE N'нет' END,
    CASE WHEN
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%ALTER INDEX%REORGANIZE%'
            OR st.command LIKE '%ALTER INDEX%REBUILD%'
            OR st.command LIKE '%IndexOptimize%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Reorganize Index Task%'
            OR st.command LIKE '%Rebuild Index Task%'
            OR st.command LIKE '%Реорганизация индексов%'
            OR st.command LIKE '%Перестройка индексов%'
            OR st.command LIKE '%subplan%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Index%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%индекс%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Reorg%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Rebuild%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND (st.command LIKE '%Invoke-DbaIndexOptimize%'
            OR st.command LIKE '%Optimize-DbaIndex%')
      )
    THEN 'true' ELSE 'false' END

UNION ALL
SELECT 116, 'maintenance',
    'checkdb_job_exists',
    N'Регламентное задание проверки целостности БД',
    CASE WHEN
      -- Команды T-SQL
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%DBCC CHECKDB%'
            OR st.command LIKE '%DatabaseIntegrityCheck%')
      )
      -- Пакеты SSIS
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Check Database Integrity Task%'
            OR st.command LIKE '%Проверка целостности баз данных%'
            OR st.command LIKE '%subplan%')
      )
      -- Подпланы обслуживания
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Integrity%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%целостн%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%CHECKDB%')
      )
      -- Команды PowerShell
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND st.command LIKE '%Invoke-DbaDbCheck%'
      )
    THEN N'есть' ELSE N'нет' END,
    CASE WHEN
      EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'TSQL'
          AND (st.command LIKE '%DBCC CHECKDB%'
            OR st.command LIKE '%DatabaseIntegrityCheck%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'SSIS'
          AND (st.command LIKE '%Check Database Integrity Task%'
            OR st.command LIKE '%Проверка целостности баз данных%'
            OR st.command LIKE '%subplan%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysmaintplan_subplans sp
        JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
        WHERE j.enabled = 1
          AND ((sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%Integrity%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%целостн%'
            OR (sp.subplan_name COLLATE DATABASE_DEFAULT) LIKE '%CHECKDB%')
      )
      OR EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps st
        JOIN msdb.dbo.sysjobs j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = 'PowerShell'
          AND st.command LIKE '%Invoke-DbaDbCheck%'
      )
    THEN 'true' ELSE 'false' END

UNION ALL
SELECT 117, 'maintenance',
    'log_backup_overdue_full_count',
    N'FULL-recovery БД с просроченным бэкапом лога (>24 ч)',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
-- Резервное копирование журнала в модели восстановления FULL.
FROM sys.databases d
LEFT JOIN (
    SELECT database_name, MAX(backup_finish_date) AS last_log
    FROM msdb.dbo.backupset
    WHERE (type COLLATE DATABASE_DEFAULT) = 'L'
    GROUP BY database_name
) bk ON bk.database_name = d.name
WHERE d.recovery_model = 1   -- FULL
  AND d.database_id > 4
  AND (bk.last_log IS NULL OR DATEDIFF(HOUR, bk.last_log, GETDATE()) > 24)

UNION ALL

-- ============================================================================
-- СВОДКА ТЕКУЩИХ ПОКАЗАТЕЛЕЙ
-- ============================================================================

SELECT 120, 'runtime_agg',
    'count_long_snapshot_tx_60s',
    N'Активных snapshot-транзакций длительностью более 60 секунд',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
-- Активные транзакции, использующие версии строк.
FROM sys.dm_tran_active_snapshot_database_transactions
WHERE elapsed_time_seconds > 60

UNION ALL
SELECT 121, 'runtime_agg',
    'count_long_running_queries_5s',
    N'Активных запросов длительностью более 5 секунд',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
WHERE DATEDIFF(SECOND, r.start_time, GETDATE()) > 5
  AND s.is_user_process = 1
  AND r.session_id <> @@SPID

UNION ALL
SELECT 122, 'runtime_agg',
    'count_blocking_chains_active',
    N'Сеансов в активной блокировочной цепочке',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0

UNION ALL
SELECT 123, 'runtime_agg',
    'count_tempdb_pagelatch_waits',
    N'Активных PAGELATCH-ожиданий на страницах tempdb',
    CONVERT(NVARCHAR(20), COUNT(*)),
    CONVERT(NVARCHAR(20), COUNT(*))
-- Ожидания PAGELATCH, связанные с tempdb.
FROM sys.dm_os_waiting_tasks
WHERE (wait_type COLLATE DATABASE_DEFAULT) LIKE 'PAGELATCH_%'
  AND (resource_description COLLATE DATABASE_DEFAULT) LIKE '2:%'

UNION ALL
SELECT 124, 'runtime_agg',
    'min_ple_seconds',
    N'Минимальный Page Life Expectancy (по NUMA-нодам), сек',
    ISNULL(CONVERT(NVARCHAR(20), MIN(cntr_value)), N'не получено'),
    ISNULL(CONVERT(NVARCHAR(20), MIN(cntr_value)), '0')
FROM sys.dm_os_performance_counters
WHERE (counter_name COLLATE DATABASE_DEFAULT) = 'Page life expectancy'

UNION ALL
SELECT 125, 'runtime_agg',
    'max_io_latency_data_ms',
    N'Максимальная средняя задержка чтения data-файлов, мс',
    ISNULL(CONVERT(NVARCHAR(20),
        MAX(CAST(io_stall_read_ms * 1.0 / NULLIF(num_of_reads, 0) AS DECIMAL(10,2)))), '0'),
    ISNULL(CONVERT(NVARCHAR(20),
        MAX(CAST(io_stall_read_ms * 1.0 / NULLIF(num_of_reads, 0) AS DECIMAL(10,2)))), '0')
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE (mf.type_desc COLLATE DATABASE_DEFAULT) = 'ROWS' AND vfs.num_of_reads > 0

UNION ALL
SELECT 126, 'runtime_agg',
    'max_io_latency_log_ms',
    N'Максимальная средняя задержка записи log-файлов, мс',
    ISNULL(CONVERT(NVARCHAR(20),
        MAX(CAST(io_stall_write_ms * 1.0 / NULLIF(num_of_writes, 0) AS DECIMAL(10,2)))), '0'),
    ISNULL(CONVERT(NVARCHAR(20),
        MAX(CAST(io_stall_write_ms * 1.0 / NULLIF(num_of_writes, 0) AS DECIMAL(10,2)))), '0')
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE (mf.type_desc COLLATE DATABASE_DEFAULT) = 'LOG' AND vfs.num_of_writes > 0

UNION ALL
SELECT 127, 'runtime_agg',
    'tempdb_free_space_pct',
    N'Свободного места в tempdb, %',
    ISNULL(CONVERT(NVARCHAR(20),
      CAST(SUM(unallocated_extent_page_count) * 100.0
           / NULLIF(SUM(total_page_count), 0) AS DECIMAL(5, 1))), '100'),
    ISNULL(CONVERT(NVARCHAR(20),
      CAST(SUM(unallocated_extent_page_count) * 100.0
           / NULLIF(SUM(total_page_count), 0) AS DECIMAL(5, 1))), '100')
FROM sys.dm_db_file_space_usage

UNION ALL
SELECT 128, 'runtime_agg',
    'buffer_pool_pct_total',
    N'Доля buffer pool в общем потреблении памяти SQL Server, %',
    CONVERT(NVARCHAR(20),
      CAST(ISNULL((SELECT SUM(pages_kb) FROM sys.dm_os_memory_clerks
                   WHERE ([type] COLLATE DATABASE_DEFAULT) = 'MEMORYCLERK_SQLBUFFERPOOL'), 0) * 100.0
           / NULLIF((SELECT SUM(pages_kb) FROM sys.dm_os_memory_clerks), 0)
           AS DECIMAL(5, 1))),
    CONVERT(NVARCHAR(20),
      CAST(ISNULL((SELECT SUM(pages_kb) FROM sys.dm_os_memory_clerks
                   WHERE ([type] COLLATE DATABASE_DEFAULT) = 'MEMORYCLERK_SQLBUFFERPOOL'), 0) * 100.0
           / NULLIF((SELECT SUM(pages_kb) FROM sys.dm_os_memory_clerks), 0)
           AS DECIMAL(5, 1)))
FROM (SELECT 1 AS dummy) d

UNION ALL
SELECT 129, 'runtime_agg',
    'top_db_cpu_pct',
    N'Доля CPU-времени запросов топовой базы, %',
    -- Доля максимального CPU равна отношению максимума к сумме CPU по базам.
    ISNULL(CONVERT(NVARCHAR(20),
      CAST(MAX(CPU_Time_Ms) * 100.0 / NULLIF(SUM(CPU_Time_Ms), 0) AS DECIMAL(5, 1))), '0'),
    ISNULL(CONVERT(NVARCHAR(20),
      CAST(MAX(CPU_Time_Ms) * 100.0 / NULLIF(SUM(CPU_Time_Ms), 0) AS DECIMAL(5, 1))), '0')
-- Информационная метрика: какая ИБ нагружает CPU больше всех.
FROM (
  SELECT
    SUM(qs.total_worker_time) AS CPU_Time_Ms,
    F_DB.DatabaseID
  FROM sys.dm_exec_query_stats qs
  CROSS APPLY (
    SELECT CONVERT(int, value) AS DatabaseID
    FROM sys.dm_exec_plan_attributes(qs.plan_handle)
    WHERE attribute = N'dbid'
  ) F_DB
  WHERE F_DB.DatabaseID > 4
    AND F_DB.DatabaseID <> 32767
  GROUP BY F_DB.DatabaseID
) cpu

) /* CTE all_data конец */
SELECT * FROM all_data ORDER BY "N";
GO

-- ============================================================================
-- ПОКАЗАТЕЛИ SQL SERVER 2016 И НОВЕЕ
-- ----------------------------------------------------------------------------
-- Динамический SQL компилирует обращения к новым столбцам после проверки версии.
-- ============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
BEGIN
    EXEC sp_executesql N'
    SELECT 46 AS [N], ''tempdb'' AS [Section], ''tempdb_autogrow_all_files'' AS [Key],
        N''Все файлы tempdb растут одновременно (AUTOGROW_ALL_FILES)'' AS [Label],
        CASE WHEN MAX(CAST(is_autogrow_all_files AS INT)) = 1
             THEN N''включено'' ELSE N''выключено'' END AS [Display],
        CASE WHEN MAX(CAST(is_autogrow_all_files AS INT)) = 1
             THEN ''true'' ELSE ''false'' END AS [Value]
    FROM tempdb.sys.filegroups WHERE (name COLLATE DATABASE_DEFAULT) = ''PRIMARY''';

    EXEC sp_executesql N'
    SELECT 57 AS [N], ''recovery'' AS [Section], ''mixed_page_allocation_user_db_count'' AS [Key],
        N''Баз 1С со смешанным размещением страниц (MIXED_PAGE_ALLOCATION ON)'' AS [Label],
        CONVERT(NVARCHAR(20), COUNT(*)) AS [Display],
        CONVERT(NVARCHAR(20), COUNT(*)) AS [Value]
    FROM sys.databases
    WHERE database_id > 4 AND is_mixed_page_allocation_on = 1';
END
ELSE
BEGIN
    SELECT 46 AS [N], 'tempdb' AS [Section], 'tempdb_autogrow_all_files' AS [Key],
        N'Все файлы tempdb растут одновременно (AUTOGROW_ALL_FILES)' AS [Label],
        N'не поддерживается (SQL < 2016)' AS [Display],
        'n/a' AS [Value]
    UNION ALL
    SELECT 57, 'recovery', 'mixed_page_allocation_user_db_count',
        N'Баз 1С со смешанным размещением страниц (MIXED_PAGE_ALLOCATION ON)',
        N'не поддерживается (SQL < 2016)', 'n/a';
END
GO

-- ============================================================================
-- ДЕТАЛИЗАЦИЯ ТЕКУЩИХ ПОКАЗАТЕЛЕЙ
-- ============================================================================

-- Активные флаги трассировки из временной таблицы #tf.
SELECT 280 + ROW_NUMBER() OVER (ORDER BY TraceFlag) AS "N",
       'traceflags' AS "Section",
       '_tf_' + CONVERT(NVARCHAR(10), TraceFlag) AS "Key",
       'TF ' + CONVERT(NVARCHAR(10), TraceFlag) +
         CASE [Global] WHEN 1 THEN N' (глобально)' ELSE N' (только сессия)' END AS "Label",
       CASE Status WHEN 1 THEN N'активен' ELSE N'неактивен' END AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"trace_flag":' + CONVERT(NVARCHAR(10), TraceFlag)
         + ',"status":' + CONVERT(NVARCHAR(5), Status)
         + ',"global":' + CASE [Global] WHEN 1 THEN 'true' ELSE 'false' END
         + ',"session":' + CASE [Session] WHEN 1 THEN 'true' ELSE 'false' END
         + '}'
       ) AS "Value"
FROM #tf
WHERE Status = 1;
GO

SELECT 280 AS "N", 'traceflags' AS "Section",
       '_tf_none' AS "Key",
       N'Активных trace flags нет' AS "Label",
       '0' AS "Display",
       '0' AS "Value"
WHERE NOT EXISTS (SELECT 1 FROM #tf WHERE Status = 1);
GO

-- Файлы tempdb
SELECT 200 + ROW_NUMBER() OVER (ORDER BY file_id) AS "N",
       'tempdb' AS "Section",
       '_tempdb_file_' + CONVERT(NVARCHAR(10), file_id) AS "Key",
       'tempdb: ' + (name COLLATE DATABASE_DEFAULT) AS "Label",
       (type_desc COLLATE DATABASE_DEFAULT) + ' / '
         + CONVERT(NVARCHAR(20), size * 8 / 1024) + ' MB / growth '
         + CASE WHEN is_percent_growth = 1
                THEN CONVERT(NVARCHAR(10), growth) + ' %'
                ELSE CONVERT(NVARCHAR(10), growth * 8 / 1024) + ' MB'
           END AS "Display",
       CONVERT(NVARCHAR(MAX),
         -- Приведение к BIGINT до пересчёта страниц в байты предотвращает переполнение INT.
         CONVERT(NVARCHAR(20), CAST(size AS BIGINT) * 8 * 1024) + '|'
         + (type_desc COLLATE DATABASE_DEFAULT) + '|'
         + (LEFT(physical_name COLLATE DATABASE_DEFAULT, 3)) + '|'
         + CASE WHEN is_percent_growth = 1 THEN 'pct:' + CONVERT(NVARCHAR(10), growth)
                ELSE 'mb:' + CONVERT(NVARCHAR(10), CAST(growth AS BIGINT) * 8 / 1024) END
       ) AS "Value"
FROM sys.master_files
WHERE database_id = DB_ID('tempdb')
ORDER BY file_id;
GO

-- Параметры восстановления, сортировка и размеры файлов по каждой базе.
SELECT 220 + ROW_NUMBER() OVER (ORDER BY d.name) AS "N",
       'recovery' AS "Section",
       '_db_' + (d.name COLLATE DATABASE_DEFAULT) AS "Key",
       N'БД: ' + (d.name COLLATE DATABASE_DEFAULT) AS "Label",
       'recovery=' + (d.recovery_model_desc COLLATE DATABASE_DEFAULT)
         + ' / shrink=' + CASE WHEN d.is_auto_shrink_on = 1 THEN 'ON' ELSE 'OFF' END
         + ' / size=' + CASE WHEN s.total_mb >= 1024
              THEN CONVERT(NVARCHAR(20), CAST(s.total_mb / 1024.0 AS DECIMAL(15,1))) + ' GB ('
                 + CONVERT(NVARCHAR(20), CAST(s.data_mb  / 1024.0 AS DECIMAL(15,1))) + N' data + '
                 + CONVERT(NVARCHAR(20), CAST(s.log_mb   / 1024.0 AS DECIMAL(15,1))) + ' log)'
              ELSE CONVERT(NVARCHAR(20), s.total_mb) + ' MB ('
                 + CONVERT(NVARCHAR(20), s.data_mb) + N' data + '
                 + CONVERT(NVARCHAR(20), s.log_mb) + ' log)'
              END
         + ' / collation=' + ISNULL(d.collation_name COLLATE DATABASE_DEFAULT, 'n/a')
         + ' / compat=' + CONVERT(NVARCHAR(10), d.compatibility_level)
         + ' / page_verify=' + (d.page_verify_option_desc COLLATE DATABASE_DEFAULT) AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"recovery":"' + (d.recovery_model_desc COLLATE DATABASE_DEFAULT) + '"'
         + ',"auto_shrink":' + CASE WHEN d.is_auto_shrink_on = 1 THEN 'true' ELSE 'false' END
         + ',"size_mb":'    + CONVERT(NVARCHAR(20), s.total_mb)
         + ',"data_mb":'    + CONVERT(NVARCHAR(20), s.data_mb)
         + ',"log_mb":'     + CONVERT(NVARCHAR(20), s.log_mb)
         + ',"collation":"' + ISNULL(d.collation_name COLLATE DATABASE_DEFAULT, '') + '"'
         + ',"compat":'     + CONVERT(NVARCHAR(10), d.compatibility_level)
         + ',"page_verify":"' + (d.page_verify_option_desc COLLATE DATABASE_DEFAULT) + '"'
         + ',"is_user_db":' + CASE WHEN d.database_id > 4 THEN 'true' ELSE 'false' END
         + '}'
       ) AS "Value"
FROM sys.databases d
CROSS APPLY (
    SELECT
        SUM(CAST(size AS BIGINT)) * 8 / 1024 AS total_mb,
        SUM(CASE WHEN (type_desc COLLATE DATABASE_DEFAULT) = 'ROWS'
                 THEN CAST(size AS BIGINT) ELSE 0 END) * 8 / 1024 AS data_mb,
        SUM(CASE WHEN (type_desc COLLATE DATABASE_DEFAULT) = 'LOG'
                 THEN CAST(size AS BIGINT) ELSE 0 END) * 8 / 1024 AS log_mb
    FROM sys.master_files
    WHERE database_id = d.database_id
) s
WHERE d.database_id <= 4 OR (d.state_desc COLLATE DATABASE_DEFAULT) = 'ONLINE';
GO

-- Задержка операций ввода-вывода по файлам.
SELECT 350 + ROW_NUMBER() OVER (ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC) AS "N",
       'io' AS "Section",
       '_lat_' + CONVERT(NVARCHAR(10), vfs.database_id) + '_' + CONVERT(NVARCHAR(10), vfs.file_id) AS "Key",
       (DB_NAME(vfs.database_id) COLLATE DATABASE_DEFAULT) + ' / ' + (mf.name COLLATE DATABASE_DEFAULT) AS "Label",
       (mf.type_desc COLLATE DATABASE_DEFAULT) + ' / read '
         + CONVERT(NVARCHAR(20), CAST(vfs.io_stall_read_ms * 1.0 /
             NULLIF(vfs.num_of_reads, 0) AS DECIMAL(10,2))) + ' ms / write '
         + CONVERT(NVARCHAR(20), CAST(vfs.io_stall_write_ms * 1.0 /
             NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,2))) + ' ms' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"avg_read_ms":' + ISNULL(CONVERT(NVARCHAR(20),
             CAST(vfs.io_stall_read_ms * 1.0 / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(10,2))), 'null')
         + ',"avg_write_ms":' + ISNULL(CONVERT(NVARCHAR(20),
             CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,2))), 'null')
         + ',"type":"' + (mf.type_desc COLLATE DATABASE_DEFAULT) + '"'
         + ',"db":"' + (DB_NAME(vfs.database_id) COLLATE DATABASE_DEFAULT) + '"'
         + '}'
       ) AS "Value"
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf
  ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE (vfs.io_stall_read_ms + vfs.io_stall_write_ms) > 0
ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;
GO

-- Распределение ALLOW_PAGE_LOCKS по индексам текущей базы.
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
  AND DB_ID() > 4
HAVING COUNT(*) > 0;
GO

-- Логины и серверные роли (группировка по логину)
SELECT 260 + ROW_NUMBER() OVER (ORDER BY (sp.name COLLATE DATABASE_DEFAULT)) AS "N",
       'auth' AS "Section",
       '_login_' + (sp.name COLLATE DATABASE_DEFAULT) AS "Key",
       N'Логин: ' + (sp.name COLLATE DATABASE_DEFAULT) + ' (' + (sp.type_desc COLLATE DATABASE_DEFAULT) + ')' AS "Label",
       ISNULL(STUFF((
         SELECT ', ' + (sr.name COLLATE DATABASE_DEFAULT)
         FROM sys.server_role_members srm
         JOIN sys.server_principals sr ON sr.principal_id = srm.role_principal_id
         WHERE srm.member_principal_id = sp.principal_id
         FOR XML PATH('')
       ), 1, 2, ''), '(public only)') AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"type":"' + (sp.type_desc COLLATE DATABASE_DEFAULT)
         + '","is_disabled":' + CASE WHEN sp.is_disabled = 1 THEN 'true' ELSE 'false' END
         + ',"roles":"' + ISNULL(STUFF((
             SELECT ',' + (sr.name COLLATE DATABASE_DEFAULT)
             FROM sys.server_role_members srm
             JOIN sys.server_principals sr ON sr.principal_id = srm.role_principal_id
             WHERE srm.member_principal_id = sp.principal_id
             FOR XML PATH('')
           ), 1, 1, ''), '') + '"}'
       ) AS "Value"
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U')
  AND (sp.name COLLATE DATABASE_DEFAULT) NOT LIKE '##%'
  AND (sp.name COLLATE DATABASE_DEFAULT) NOT IN ('NT AUTHORITY\SYSTEM', 'NT SERVICE\MSSQLSERVER')
ORDER BY (sp.name COLLATE DATABASE_DEFAULT);
GO

-- ============================================================================
-- ИСТОРИЯ БЭКАПОВ (последние Full / Diff / Log по каждой пользовательской БД)
-- ============================================================================

SELECT 420 + ROW_NUMBER() OVER (ORDER BY database_name) AS "N",
       'maintenance' AS "Section",
       '_backup_' + database_name AS "Key",
       N'Бэкапы БД: ' + database_name AS "Label",
       'Full: ' + ISNULL(CONVERT(NVARCHAR(20),
         DATEDIFF(HOUR, MAX(CASE WHEN type = 'D' THEN backup_finish_date END), GETDATE())) + N' ч назад',
         N'нет')
       + ' / Diff: ' + ISNULL(CONVERT(NVARCHAR(20),
         DATEDIFF(HOUR, MAX(CASE WHEN type = 'I' THEN backup_finish_date END), GETDATE())) + N' ч назад',
         N'нет')
       + ' / Log: ' + ISNULL(CONVERT(NVARCHAR(20),
         DATEDIFF(MINUTE, MAX(CASE WHEN type = 'L' THEN backup_finish_date END), GETDATE())) + N' мин назад',
         N'нет') AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"hours_since_full":' + ISNULL(CONVERT(NVARCHAR(20),
             DATEDIFF(HOUR, MAX(CASE WHEN type = 'D' THEN backup_finish_date END), GETDATE())), 'null')
         + ',"hours_since_diff":' + ISNULL(CONVERT(NVARCHAR(20),
             DATEDIFF(HOUR, MAX(CASE WHEN type = 'I' THEN backup_finish_date END), GETDATE())), 'null')
         + ',"minutes_since_log":' + ISNULL(CONVERT(NVARCHAR(20),
             DATEDIFF(MINUTE, MAX(CASE WHEN type = 'L' THEN backup_finish_date END), GETDATE())), 'null')
         + '}'
       ) AS "Value"
FROM msdb.dbo.backupset bs
JOIN sys.databases d ON d.name = bs.database_name
WHERE d.database_id > 4
GROUP BY database_name;
GO

-- ============================================================================
-- ТИПЫ ОЖИДАНИЙ ПО СУММАРНОМУ ВРЕМЕНИ
-- ============================================================================

SELECT 500 + ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC) AS "N",
       'runtime' AS "Section",
       '_wait_' + REPLACE(wait_type, '_', '_') AS "Key",
       'Wait: ' + wait_type AS "Label",
       CONVERT(NVARCHAR(20), waiting_tasks_count) + ' waits / '
       + CONVERT(NVARCHAR(20), CAST(wait_time_ms / 1000.0 AS DECIMAL(18,2))) + ' s total / '
       + CONVERT(NVARCHAR(20), CAST((wait_time_ms - signal_wait_time_ms) / 1000.0 AS DECIMAL(18,2))) + ' s resource' AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"waits":' + CONVERT(NVARCHAR(20), waiting_tasks_count)
         + ',"total_ms":' + CONVERT(NVARCHAR(20), wait_time_ms)
         + ',"resource_ms":' + CONVERT(NVARCHAR(20), wait_time_ms - signal_wait_time_ms)
         + ',"signal_ms":' + CONVERT(NVARCHAR(20), signal_wait_time_ms)
         + '}'
       ) AS "Value"
FROM sys.dm_os_wait_stats
WHERE (wait_type COLLATE DATABASE_DEFAULT) IN (
  'CXPACKET','CXCONSUMER',
  'LCK_M_S','LCK_M_X','LCK_M_U','LCK_M_IS','LCK_M_IX',
  'PAGELATCH_EX','PAGELATCH_SH',
  'PAGEIOLATCH_SH','PAGEIOLATCH_EX',
  'WRITELOG','SOS_SCHEDULER_YIELD',
  'ASYNC_NETWORK_IO','THREADPOOL'
)
AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;
GO

-- ============================================================================
-- ДЛИТЕЛЬНЫЕ АКТИВНЫЕ ЗАПРОСЫ
-- ============================================================================

SELECT 520 + ROW_NUMBER() OVER (ORDER BY r.start_time) AS "N",
       'runtime' AS "Section",
       '_long_' + CONVERT(NVARCHAR(10), r.session_id) AS "Key",
       N'Запрос spid=' + CONVERT(NVARCHAR(10), r.session_id)
         + ' (' + ISNULL(s.program_name, '?') + ')' AS "Label",
       CONVERT(NVARCHAR(20), DATEDIFF(SECOND, r.start_time, GETDATE())) + N' с / '
         + (DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT) + ' / wait=' + ISNULL((r.wait_type COLLATE DATABASE_DEFAULT), 'none')
         + (CASE WHEN r.blocking_session_id <> 0
                 THEN ' / blocked by spid=' + CONVERT(NVARCHAR(10), r.blocking_session_id)
                 ELSE '' END) AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"spid":' + CONVERT(NVARCHAR(10), r.session_id)
         + ',"duration_sec":' + CONVERT(NVARCHAR(20), DATEDIFF(SECOND, r.start_time, GETDATE()))
         + ',"db":"' + (DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT) + '"'
         + ',"wait_type":"' + ISNULL((r.wait_type COLLATE DATABASE_DEFAULT), '') + '"'
         + ',"blocking_spid":' + CONVERT(NVARCHAR(10), r.blocking_session_id)
         + ',"login":"' + ISNULL(s.login_name, '') + '"'
         + ',"host":"' + ISNULL(s.host_name, '') + '"'
         + ',"program":"' + REPLACE(ISNULL(s.program_name, ''), '"', '\"') + '"'
         + '}'
       ) AS "Value"
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
WHERE DATEDIFF(SECOND, r.start_time, GETDATE()) > 5
  AND s.is_user_process = 1
  AND r.session_id <> @@SPID;
GO

-- ============================================================================
-- ЦЕПОЧКИ БЛОКИРОВОК
-- ============================================================================

SELECT 540 + ROW_NUMBER() OVER (ORDER BY r.wait_time DESC) AS "N",
       'runtime' AS "Section",
       '_block_' + CONVERT(NVARCHAR(10), r.session_id) AS "Key",
       N'Блокировка spid=' + CONVERT(NVARCHAR(10), r.session_id)
         + N' от spid=' + CONVERT(NVARCHAR(10), r.blocking_session_id) AS "Label",
       N'Жду ' + CONVERT(NVARCHAR(20), r.wait_time / 1000) + N' с / '
         + (DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT) + ' / ' + ISNULL((r.wait_type COLLATE DATABASE_DEFAULT), '?') AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"blocked_spid":' + CONVERT(NVARCHAR(10), r.session_id)
         + ',"blocker_spid":' + CONVERT(NVARCHAR(10), r.blocking_session_id)
         + ',"wait_sec":' + CONVERT(NVARCHAR(20), r.wait_time / 1000)
         + ',"wait_type":"' + ISNULL((r.wait_type COLLATE DATABASE_DEFAULT), '') + '"'
         + ',"db":"' + (DB_NAME(r.database_id) COLLATE DATABASE_DEFAULT) + '"'
         + '}'
       ) AS "Value"
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id <> 0;
GO

-- ============================================================================
-- TempDB CONTENTION (текущие waits на PFS/GAM/SGAM)
-- ============================================================================

SELECT 560 + ROW_NUMBER() OVER (ORDER BY wait_duration_ms DESC) AS "N",
       'runtime' AS "Section",
       '_tdb_contention_' + CONVERT(NVARCHAR(10), session_id) AS "Key",
       'TempDB contention spid=' + CONVERT(NVARCHAR(10), session_id) AS "Label",
       wait_type + ' / ' + CONVERT(NVARCHAR(20), wait_duration_ms) + ' ms / page=' + ISNULL(resource_description, '?') AS "Display",
       CONVERT(NVARCHAR(MAX),
         '{"spid":' + CONVERT(NVARCHAR(10), session_id)
         + ',"wait_type":"' + wait_type + '"'
         + ',"wait_duration_ms":' + CONVERT(NVARCHAR(20), wait_duration_ms)
         + ',"page":"' + ISNULL(resource_description, '') + '"'
         + '}'
       ) AS "Value"
FROM sys.dm_os_waiting_tasks
WHERE (wait_type COLLATE DATABASE_DEFAULT) LIKE 'PAGELATCH_%'
  AND (resource_description COLLATE DATABASE_DEFAULT) LIKE '2:%';
GO

-- ============================================================================
-- PAGE LIFE EXPECTANCY (PLE) — по NUMA-узлам
-- ============================================================================

SELECT 580 + ROW_NUMBER() OVER (ORDER BY instance_name) AS "N",
       'runtime' AS "Section",
       '_ple_' + ISNULL(NULLIF(instance_name, ''), 'global') AS "Key",
       'Page Life Expectancy ('
         + CASE WHEN instance_name = '' THEN 'global'
                ELSE 'NUMA-node ' + instance_name END + ')' AS "Label",
       CONVERT(NVARCHAR(20), cntr_value) + N' сек' AS "Display",
       CONVERT(NVARCHAR(20), cntr_value) AS "Value"
FROM sys.dm_os_performance_counters
WHERE (counter_name COLLATE DATABASE_DEFAULT) = 'Page life expectancy';
GO

-- ============================================================================
-- СТАТИСТИКА В ТЕКУЩЕЙ БАЗЕ
-- ============================================================================

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
-- Полный снимок sys.configurations
-- ----------------------------------------------------------------------------
-- SQL Server 2014 формирует массив через FOR XML PATH.
-- SQL Server 2016 и новее используют FOR JSON PATH.
-- ============================================================================

DECLARE @sys_config_full NVARCHAR(MAX);

IF CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')) >= 13
    EXEC sys.sp_executesql N'
        SET @snapshot = (
            SELECT name, value_in_use, [value], [minimum], [maximum], is_dynamic, is_advanced
            FROM sys.configurations
            ORDER BY name
            FOR JSON PATH
        )', N'@snapshot NVARCHAR(MAX) OUTPUT', @snapshot = @sys_config_full OUTPUT;
ELSE
BEGIN
    SET @sys_config_full = (
        SELECT N',{"name":"' + REPLACE(REPLACE(name, N'\', N'\\'), N'"', N'\"') + N'"'
            + N',"value_in_use":' + COALESCE(CONVERT(NVARCHAR(30), value_in_use), N'null')
            + N',"value":' + COALESCE(CONVERT(NVARCHAR(30), [value]), N'null')
            + N',"minimum":' + COALESCE(CONVERT(NVARCHAR(30), [minimum]), N'null')
            + N',"maximum":' + COALESCE(CONVERT(NVARCHAR(30), [maximum]), N'null')
            + N',"is_dynamic":' + CASE is_dynamic WHEN 1 THEN N'true' WHEN 0 THEN N'false' ELSE N'null' END
            + N',"is_advanced":' + CASE is_advanced WHEN 1 THEN N'true' WHEN 0 THEN N'false' ELSE N'null' END
            + N'}'
        FROM sys.configurations
        ORDER BY name
        FOR XML PATH('')
    );

    -- Декодируем текстовые XML-сущности после склейки строк.
    SET @sys_config_full = REPLACE(REPLACE(REPLACE(@sys_config_full,
        N'&lt;', N'<'), N'&gt;', N'>'), N'&amp;', N'&');
    SET @sys_config_full = N'[' + COALESCE(STUFF(@sys_config_full, 1, 1, N''), N'') + N']';
END;

SELECT 999 AS "N", 'instance_config' AS "Section",
    '_sys_configurations_full' AS "Key",
    N'Полный снимок sys.configurations (forensic, v2.12)' AS "Label",
    N'' AS "Display",
    ISNULL(@sys_config_full, N'[]') AS "Value";
GO
