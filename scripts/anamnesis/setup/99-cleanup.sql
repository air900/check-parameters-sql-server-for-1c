-- =============================================================================
-- 99-cleanup.sql
-- Удаляет сессию Extended Events этой базы и сбрасывает серверную настройку
-- длительных блокировок. Параметр reset_qs=1 также выключает Query Store.
-- =============================================================================
SET NOCOUNT ON;
DECLARE @db SYSNAME = CONVERT(nvarchar(128), 0x$(db_hex));
DECLARE @database_id INT = DB_ID(@db);
IF @database_id IS NULL OR @database_id <= 4
    THROW 50000, N'Укажите доступную пользовательскую базу SQL Server.', 1;

DECLARE @session_name SYSNAME = N'_diag_1c_anamnesis_' + CONVERT(nvarchar(10), @database_id);
DECLARE @reset_qs BIT = TRY_CAST(N'$(reset_qs)' AS BIT);
IF @reset_qs IS NULL SET @reset_qs = 0;

-- 1. XE session
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @session_name)
BEGIN
    DECLARE @drop NVARCHAR(MAX) = N'DROP EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER;';
    EXEC sp_executesql @drop;
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
