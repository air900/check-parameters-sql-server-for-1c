-- =============================================================================
-- 99-cleanup.sql
-- Полный откат всего, что устанавливают 01..03.
-- Идемпотентно — можно запустить даже если установка не делалась.
-- Параметры: -v db=eshn_test1 reset_qs=1
--   reset_qs=1  → выключить Query Store (по умолчанию 0 — оставить включённым,
--                 он безопасен и его данные могут пригодиться).
-- =============================================================================
SET NOCOUNT ON;
DECLARE @db SYSNAME = N'$(db)';
DECLARE @reset_qs BIT = TRY_CAST(N'$(reset_qs)' AS BIT);
IF @reset_qs IS NULL SET @reset_qs = 0;

-- 1. XE session
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'_diag_eshn_hang')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'_diag_eshn_hang')
        ALTER EVENT SESSION [_diag_eshn_hang] ON SERVER STATE = STOP;
    DROP EVENT SESSION [_diag_eshn_hang] ON SERVER;
    PRINT N'XE session удалена.';
END;

-- 2. BPT — возвращаем в 0
IF (SELECT CAST(value_in_use AS INT) FROM sys.configurations
    WHERE name = N'blocked process threshold (s)') <> 0
BEGIN
    EXEC sp_configure N'blocked process threshold (s)', 0;
    RECONFIGURE;
    PRINT N'BPT возвращён в 0.';
END;

-- 3. Query Store (опционально)
IF @reset_qs = 1
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET QUERY_STORE = OFF;';
    EXEC sp_executesql @sql;
    PRINT N'Query Store выключен на ' + @db;
END
ELSE
BEGIN
    PRINT N'Query Store оставлен включённым (reset_qs=0). Чтобы выключить: -v reset_qs=1';
END;

-- 4. Auto Plan Correction оставляем — он безопасен.

PRINT N'Cleanup завершён.';
