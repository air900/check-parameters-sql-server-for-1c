-- =============================================================================
-- 03-create-xe-session.sql
-- Создаёт Extended Events session для пассивного захвата:
--   - blocked_process_report (требует BPT > 0 — см. 02-)
--   - sql_batch_completed > 5s на eshn_test1
--   - rpc_completed > 5s на eshn_test1
-- Файлы пишутся в C:\Anamnesis\data\xe\, ring 5 файлов по 100 MB.
-- Идемпотентно — пересоздаёт session если уже есть.
-- =============================================================================
SET NOCOUNT ON;
DECLARE @db SYSNAME = N'$(db)';
DECLARE @session_name SYSNAME = N'_diag_eshn_hang';
DECLARE @file_path NVARCHAR(260) = N'C:\Anamnesis\data\xe\_diag_eshn_hang.xel';

-- Удаляем старую session если есть
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @session_name)
BEGIN
    DECLARE @drop NVARCHAR(MAX) = N'DROP EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER;';
    EXEC sp_executesql @drop;
    PRINT N'Старая session удалена.';
END;

-- Создаём папку для XE-файлов (через xp_cmdshell ОТКЛЮЧЕНО по умолчанию,
-- так что папку создаёт install-anamnesis.ps1 автоматически: C:\Anamnesis\data\xe)

DECLARE @sql NVARCHAR(MAX) = N'
CREATE EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.sql_batch_completed (
    SET collect_batch_text = (1)
    ACTION (sqlserver.session_id, sqlserver.client_app_name, sqlserver.database_name, sqlserver.sql_text)
    WHERE database_name = N''' + @db + N''' AND duration > 5000000
),
ADD EVENT sqlserver.rpc_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.session_id, sqlserver.client_app_name, sqlserver.database_name)
    WHERE database_name = N''' + @db + N''' AND duration > 5000000
)
ADD TARGET package0.event_file (
    SET filename = N''' + @file_path + N''',
        max_file_size = 100,
        max_rollover_files = 5
)
WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY = 30 SECONDS, STARTUP_STATE = OFF);

ALTER EVENT SESSION ' + QUOTENAME(@session_name) + N' ON SERVER STATE = START;
';
EXEC sp_executesql @sql;

PRINT N'XE session запущена. Файлы: ' + @file_path;
PRINT N'ВАЖНО: папка C:\Anamnesis\data\xe\ создаётся автоматически install-anamnesis.ps1.';

-- Сводка: startup_state — из server_event_sessions (definition);
-- create_time — из dm_xe_sessions (running); target_name — из server_event_session_targets.
SELECT
    ses.name,
    ses.startup_state,
    s.create_time,
    t.target_name
FROM sys.server_event_sessions ses
LEFT JOIN sys.dm_xe_sessions s
    ON s.name = ses.name
LEFT JOIN sys.server_event_session_targets t
    ON ses.event_session_id = t.event_session_id
WHERE ses.name = @session_name;
