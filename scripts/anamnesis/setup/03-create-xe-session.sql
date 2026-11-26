-- =============================================================================
-- 03-create-xe-session.sql
-- Записывает блокировки и длительные запросы в файлы Extended Events.
-- Имя базы и каталог передаются как последовательности байтов UTF-16 LE.
-- =============================================================================
SET NOCOUNT ON;
DECLARE @database_id INT = DB_ID(CONVERT(nvarchar(128), 0x$(db_hex)));
IF @database_id IS NULL OR @database_id <= 4
    THROW 50000, N'Укажите доступную пользовательскую базу SQL Server.', 1;

DECLARE @session_name SYSNAME = N'_diag_1c_anamnesis_' + CONVERT(nvarchar(10), @database_id);
DECLARE @file_path NVARCHAR(4000) = CONVERT(nvarchar(4000), 0x$(xe_dir_hex)) + N'\' + @session_name + N'.xel';
IF LEN(@file_path) > 260
    THROW 50000, N'Слишком длинный путь к файлу Extended Events.', 1;

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @session_name)
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.server_event_sessions AS s
        JOIN sys.server_event_session_targets AS t ON t.event_session_id = s.event_session_id
        JOIN sys.server_event_session_fields AS f
          ON f.event_session_id = t.event_session_id AND f.object_id = t.target_id
        WHERE s.name = @session_name AND t.name = N'event_file' AND f.name = N'filename'
          AND CONVERT(nvarchar(4000), f.value) = @file_path
    )
        THROW 50000, N'Существующая сессия Extended Events пишет в другой каталог.', 1;

    DECLARE @start NVARCHAR(MAX) = N'ALTER EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER STATE = START;';
    IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @session_name)
        EXEC sp_executesql @start;
    PRINT N'Сессия Extended Events запущена. Файлы: ' + @file_path;
    RETURN;
END;

DECLARE @sql NVARCHAR(MAX) = N'
CREATE EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.sql_batch_completed (
    SET collect_batch_text = (1)
    ACTION (sqlserver.session_id, sqlserver.client_app_name, sqlserver.database_name, sqlserver.sql_text)
    WHERE ([sqlserver].[database_id] = (' + CONVERT(nvarchar(10), @database_id) + N') AND [duration] > (5000000))
),
ADD EVENT sqlserver.rpc_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.session_id, sqlserver.client_app_name, sqlserver.database_name)
    WHERE ([sqlserver].[database_id] = (' + CONVERT(nvarchar(10), @database_id) + N') AND [duration] > (5000000))
)
ADD TARGET package0.event_file (
    SET filename = N''' + REPLACE(@file_path, N'''', N'''''' ) + N''',
        max_file_size = 100,
        max_rollover_files = 5
)
WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY = 30 SECONDS, STARTUP_STATE = OFF);

ALTER EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER STATE = START;
';
EXEC sp_executesql @sql;

PRINT N'Сессия Extended Events запущена. Файлы: ' + @file_path;
