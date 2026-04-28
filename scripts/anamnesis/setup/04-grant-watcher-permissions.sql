-- =============================================================================
-- 04-grant-watcher-permissions.sql
--
-- Anamnesis-watcher запускается как Windows scheduled task под учётной
-- записью NT AUTHORITY\SYSTEM. По умолчанию (SQL Server 2014+):
--   - BUILTIN\Administrators больше НЕ sysadmin
--   - У NT AUTHORITY\SYSTEM нет VIEW SERVER STATE / VIEW DATABASE STATE
-- Поэтому DMV-запросы из Snapshot-OneShot.sql валятся:
--   Msg 297, level 16: "У пользователя нет разрешения на выполнение этого действия"
--
-- Что выдаём NT AUTHORITY\SYSTEM:
--   VIEW SERVER STATE    — все sys.dm_exec_*, sys.dm_os_*, sys.dm_tran_*
--   VIEW ANY DEFINITION  — sys.dm_exec_sql_text + sys.dm_exec_query_plan
--   VIEW DATABASE STATE  — на целевой БД: sys.dm_db_*, query_store_*
--
-- Параметр: -v db=eshn_test1
-- =============================================================================
SET NOCOUNT ON;

DECLARE @db SYSNAME = N'$(db)';

-- 1. SQL-логин для NT AUTHORITY\SYSTEM
IF NOT EXISTS (
    SELECT 1 FROM sys.server_principals WHERE name = N'NT AUTHORITY\SYSTEM'
)
BEGIN
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
    PRINT N'Создан логин NT AUTHORITY\SYSTEM.';
END
ELSE
    PRINT N'Логин NT AUTHORITY\SYSTEM уже существует.';

-- 2. Server-level права
GRANT VIEW SERVER STATE TO [NT AUTHORITY\SYSTEM];
PRINT N'GRANT VIEW SERVER STATE -> NT AUTHORITY\SYSTEM.';

GRANT VIEW ANY DEFINITION TO [NT AUTHORITY\SYSTEM];
PRINT N'GRANT VIEW ANY DEFINITION -> NT AUTHORITY\SYSTEM.';

-- 3. Database-level права на целевой БД (через dynamic SQL —
--    USE требует константного имени, поэтому через sp_executesql)
DECLARE @sql NVARCHAR(MAX) = N'USE ' + QUOTENAME(@db) + N';
IF NOT EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = N''NT AUTHORITY\SYSTEM''
)
BEGIN
    CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
END;
GRANT VIEW DATABASE STATE TO [NT AUTHORITY\SYSTEM];';
EXEC sp_executesql @sql;
PRINT N'GRANT VIEW DATABASE STATE на [' + @db + N'] -> NT AUTHORITY\SYSTEM.';

-- 4. Подтверждение
IF EXISTS (
    SELECT 1
    FROM sys.server_permissions sp
    JOIN sys.server_principals pr ON sp.grantee_principal_id = pr.principal_id
    WHERE pr.name = N'NT AUTHORITY\SYSTEM'
      AND sp.permission_name = N'VIEW SERVER STATE'
      AND sp.state IN ('G', 'W')
)
    PRINT N'Готово: NT AUTHORITY\SYSTEM имеет VIEW SERVER STATE.';
ELSE
    PRINT N'ОШИБКА: VIEW SERVER STATE для NT AUTHORITY\SYSTEM НЕ выдан.';
