-- =============================================================================
-- Snapshot-OneShot.sql
-- Возвращает ОДНУ строку — JSON-объект с 7 ключами (FOR JSON PATH, WITHOUT_ARRAY_WRAPPER).
-- Использует FOR JSON PATH; каждая секция всегда массив (даже пустой).
-- SQL Server 2016+ требуется (FOR JSON).
-- Параметр: -v db=eshn_test1
-- =============================================================================
SET NOCOUNT ON;
DECLARE @db SYSNAME = N'$(db)';
DECLARE @db_id INT = DB_ID(@db);

DECLARE @requests NVARCHAR(MAX), @waits NVARCHAR(MAX), @locks NVARCHAR(MAX),
        @memory_grants NVARCHAR(MAX), @tempdb_usage NVARCHAR(MAX),
        @blocking NVARCHAR(MAX), @qstore_top NVARCHAR(MAX);

-- 1. requests (top 30 active by cpu_time)
-- query_plan      — кэшированный план (sys.dm_exec_query_plan), часто NULL для in-flight
-- query_stats_xml — live actual-rows план (sys.dm_exec_query_statistics_xml, SQL 2016 SP1+)
-- Берём оба: первый сохраняется для уже завершившихся к моменту снимка планов,
-- второй — единственный способ увидеть план активной долгой сессии (1С-расчёт).
SET @requests = (
    SELECT TOP 30
        r.session_id, r.start_time, r.status, r.command,
        r.wait_type, r.wait_time, r.last_wait_type, r.cpu_time,
        r.reads, r.writes, r.logical_reads,
        DATEDIFF(SECOND, r.start_time, GETDATE()) AS elapsed_sec,
        r.blocking_session_id, r.granted_query_memory,
        SUBSTRING(t.text, r.statement_start_offset/2+1,
            (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
                 ELSE r.statement_end_offset END - r.statement_start_offset)/2+1) AS sql_text,
        CONVERT(NVARCHAR(MAX), qp.query_plan) AS query_plan,
        CONVERT(NVARCHAR(MAX), qsx.query_plan) AS query_stats_xml,
        CONVERT(VARCHAR(34), r.plan_handle, 1) AS plan_handle
    FROM sys.dm_exec_requests r
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
    OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) qp
    OUTER APPLY sys.dm_exec_query_statistics_xml(r.session_id) qsx
    WHERE r.session_id <> @@SPID
      AND EXISTS (SELECT 1 FROM sys.dm_exec_sessions s WHERE s.session_id = r.session_id AND s.is_user_process = 1)
    ORDER BY r.cpu_time DESC
    FOR JSON PATH, INCLUDE_NULL_VALUES
);

-- 2. waits (cumulative — Layer 3 считает delta)
SET @waits = (
    SELECT wait_type, waiting_tasks_count, wait_time_ms,
           max_wait_time_ms, signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        N'CLR_SEMAPHORE', N'LAZYWRITER_SLEEP', N'RESOURCE_QUEUE', N'SLEEP_TASK',
        N'SLEEP_SYSTEMTASK', N'SQLTRACE_BUFFER_FLUSH', N'WAITFOR', N'LOGMGR_QUEUE',
        N'CHECKPOINT_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH', N'XE_TIMER_EVENT',
        N'BROKER_TO_FLUSH', N'BROKER_TASK_STOP', N'CLR_MANUAL_EVENT',
        N'CLR_AUTO_EVENT', N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT',
        N'XE_DISPATCHER_WAIT', N'XE_DISPATCHER_JOIN', N'BROKER_EVENTHANDLER',
        N'TRACEWRITE', N'FT_IFTSHC_MUTEX', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        N'BROKER_RECEIVE_WAITFOR', N'ONDEMAND_TASK_QUEUE', N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRRORING_CMD', N'BROKER_TRANSMITTER', N'SQLTRACE_WAIT_ENTRIES'
    )
    AND waiting_tasks_count > 0
    FOR JSON PATH, INCLUDE_NULL_VALUES
);

-- 3. locks (агрегированно — count по типу/режиму, чтобы JSON был компактным)
SET @locks = (
    SELECT resource_type, request_mode, COUNT(*) AS cnt
    FROM sys.dm_tran_locks
    WHERE resource_database_id = @db_id
    GROUP BY resource_type, request_mode
    FOR JSON PATH
);

-- 4. memory_grants (только активные)
SET @memory_grants = (
    SELECT session_id, request_id, requested_memory_kb, granted_memory_kb,
           used_memory_kb, ideal_memory_kb, queue_id, wait_time_ms,
           is_next_candidate
    FROM sys.dm_exec_query_memory_grants
    FOR JSON PATH, INCLUDE_NULL_VALUES
);

-- 5. tempdb_usage (per session)
SET @tempdb_usage = (
    SELECT TOP 30
        tsu.session_id,
        SUM(tsu.internal_objects_alloc_page_count) AS internal_alloc_pages,
        SUM(tsu.user_objects_alloc_page_count) AS user_alloc_pages,
        SUM(tsu.internal_objects_dealloc_page_count) AS internal_dealloc_pages,
        SUM(tsu.user_objects_dealloc_page_count) AS user_dealloc_pages
    FROM sys.dm_db_task_space_usage tsu
    WHERE EXISTS (SELECT 1 FROM sys.dm_exec_sessions s WHERE s.session_id = tsu.session_id AND s.is_user_process = 1)
    GROUP BY tsu.session_id
    HAVING SUM(internal_objects_alloc_page_count) + SUM(user_objects_alloc_page_count) > 0
    ORDER BY SUM(internal_objects_alloc_page_count) + SUM(user_objects_alloc_page_count) DESC
    FOR JSON PATH
);

-- 6. blocking (head + chain)
SET @blocking = (
    SELECT
        ow.blocking_session_id,
        ow.session_id AS blocked_session_id,
        ow.wait_type,
        ow.wait_duration_ms,
        ow.resource_description
    FROM sys.dm_os_waiting_tasks ow
    WHERE ow.blocking_session_id IS NOT NULL
      AND ow.blocking_session_id <> ow.session_id
    FOR JSON PATH, INCLUDE_NULL_VALUES
);

-- 7. qstore_top (если QS включён на @db)
-- ВАЖНО: FOR JSON запрещено в INSERT...EXEC (Msg 13602). Поэтому забираем результат
-- через sp_executesql с OUTPUT-параметром: внутри @qsql выражение FOR JSON присваивается
-- скалярной переменной (это разрешено), а наружу отдаётся через @json_out.
IF EXISTS (
    SELECT 1 FROM sys.databases
    WHERE name = @db AND is_query_store_on = 1
)
BEGIN
    DECLARE @qsql NVARCHAR(MAX) = N'
    SELECT @json_out = (
        SELECT TOP 10
            qsq.query_id,
            qsp.plan_id,
            qsrs.last_execution_time,
            qsrs.count_executions,
            qsrs.avg_duration / 1000.0 AS avg_duration_ms,
            qsrs.avg_cpu_time / 1000.0 AS avg_cpu_time_ms,
            qsrs.avg_logical_io_reads,
            qsrs.avg_query_max_used_memory
        FROM ' + QUOTENAME(@db) + N'.sys.query_store_query qsq
        JOIN ' + QUOTENAME(@db) + N'.sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
        JOIN ' + QUOTENAME(@db) + N'.sys.query_store_runtime_stats qsrs ON qsp.plan_id = qsrs.plan_id
        WHERE qsrs.last_execution_time > DATEADD(MINUTE, -10, GETUTCDATE())
        ORDER BY qsrs.avg_duration DESC
        FOR JSON PATH
    );';

    EXEC sp_executesql @qsql,
        N'@json_out NVARCHAR(MAX) OUTPUT',
        @json_out = @qstore_top OUTPUT;
END;

-- Финальная строка — один JSON-объект с 7 ключами (без массива-обёртки).
-- sqlcmd.exe читает его как одну строку; PowerShell: ConvertFrom-Json.
SELECT (
    SELECT
        JSON_QUERY(ISNULL(@requests,      N'[]')) AS requests,
        JSON_QUERY(ISNULL(@waits,         N'[]')) AS waits,
        JSON_QUERY(ISNULL(@locks,         N'[]')) AS locks,
        JSON_QUERY(ISNULL(@memory_grants, N'[]')) AS memory_grants,
        JSON_QUERY(ISNULL(@tempdb_usage,  N'[]')) AS tempdb_usage,
        JSON_QUERY(ISNULL(@blocking,      N'[]')) AS blocking,
        JSON_QUERY(ISNULL(@qstore_top,    N'[]')) AS qstore_top
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
