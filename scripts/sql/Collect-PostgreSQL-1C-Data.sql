-- ============================================================================
-- СБОР ДАННЫХ PostgreSQL ДЛЯ РАБОТЫ С 1С:ПРЕДПРИЯТИЕ
-- ============================================================================
--
-- Версия:       3.0
-- Дата:         2026-03-15
-- Совместимость: PostgreSQL 10–17+
-- Тип:          Сбор данных (read-only)
--
-- Назначение:
--   Сбор текущих значений параметров PostgreSQL для оценки конфигурации
--   сервера при работе с 1С:Предприятие. Скрипт выводит фактические значения
--   в двух форматах: для отображения (Display) и для машинной обработки (Value).
--
-- Колонки:
--   N       — порядковый номер для сортировки
--   Section — группа параметров (для UI)
--   Key     — техническое имя параметра (для rule engine / API)
--   Label   — человекочитаемое описание (для UI)
--   Display — значение для отображения пользователю ("128 MB", "on")
--   Value   — машиночитаемое значение (байты, секунды, true/false, числа)
--
-- Использование:
--   Откройте в pgAdmin или DBeaver, выполните целиком (F5).
--   PowerShell-скрипт использует колонки Key, Value, Display, Section.
--
-- Важно:
--   Скрипт НЕ создаёт объектов в базе данных.
--   Скрипт НЕ изменяет данные или настройки.
--   Используются только SELECT-запросы к системным представлениям.
--
-- Контакты:
--   audit-reshenie.ru | info@audit-reshenie.ru
--
-- ============================================================================

SELECT
    r."N",
    r."Section",
    r."Key",
    r."Label",
    r."Display",
    r."Value"
FROM (

-- ============================================================================
-- ИНФОРМАЦИЯ О СЕРВЕРЕ (info-параметры, не анализируются rule engine)
-- ============================================================================

SELECT 1 AS "N", 'server_info' AS "Section",
    '_info_pg_version' AS "Key",
    'Версия PostgreSQL' AS "Label",
    version() AS "Display",
    (SELECT setting FROM pg_settings WHERE name = 'server_version') AS "Value"

UNION ALL
SELECT 2, 'server_info',
    '_info_database',
    'База данных',
    current_database() || ' (' || pg_size_pretty(pg_database_size(current_database())) || ')',
    pg_database_size(current_database())::text

UNION ALL
SELECT 3, 'server_info',
    '_info_server_address',
    'Адрес сервера',
    COALESCE(inet_server_addr()::text, 'localhost') || ':' || COALESCE(inet_server_port()::text, '5432'),
    COALESCE(inet_server_port()::text, '5432')

UNION ALL
SELECT 4, 'server_info',
    '_info_uptime',
    'Время работы',
    CASE
        WHEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time())) > 0
        THEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time()))::int::text || ' дн. '
        ELSE ''
    END || to_char(now() - pg_postmaster_start_time(), 'HH24 ч. MI мин.'),
    EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::bigint::text

UNION ALL
SELECT 5, 'server_info',
    '_info_check_date',
    'Дата проверки',
    to_char(current_timestamp, 'DD.MM.YYYY HH24:MI:SS'),
    to_char(current_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS')

UNION ALL

-- ============================================================================
-- ПАМЯТЬ И КЭШ
-- ============================================================================

SELECT 10, 'memory',
    'shared_buffers',
    'Кэш данных в памяти',
    pg_size_pretty(pg_size_bytes(current_setting('shared_buffers'))),
    pg_size_bytes(current_setting('shared_buffers'))::text

UNION ALL
SELECT 11, 'memory',
    'work_mem',
    'Память для сортировок',
    pg_size_pretty(pg_size_bytes(current_setting('work_mem'))),
    pg_size_bytes(current_setting('work_mem'))::text

UNION ALL
SELECT 12, 'memory',
    'effective_cache_size',
    'Оценка доступного кэша ОС',
    pg_size_pretty(pg_size_bytes(current_setting('effective_cache_size'))),
    pg_size_bytes(current_setting('effective_cache_size'))::text

UNION ALL
SELECT 13, 'memory',
    'maintenance_work_mem',
    'Память для обслуживания БД',
    pg_size_pretty(pg_size_bytes(current_setting('maintenance_work_mem'))),
    pg_size_bytes(current_setting('maintenance_work_mem'))::text

UNION ALL
SELECT 14, 'memory',
    'huge_pages',
    'Большие страницы памяти',
    current_setting('huge_pages'),
    current_setting('huge_pages')

UNION ALL
SELECT 15, 'memory',
    'hash_mem_multiplier',
    'Множитель памяти для хэш-операций',
    current_setting('hash_mem_multiplier'),
    current_setting('hash_mem_multiplier')

UNION ALL
SELECT 16, 'memory',
    'temp_buffers',
    'Буферы временных таблиц',
    pg_size_pretty(pg_size_bytes(current_setting('temp_buffers'))),
    pg_size_bytes(current_setting('temp_buffers'))::text

UNION ALL

-- ============================================================================
-- ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)
-- ============================================================================

SELECT 20, 'wal',
    'synchronous_commit',
    'Синхронная запись при фиксации',
    current_setting('synchronous_commit'),
    CASE current_setting('synchronous_commit') WHEN 'on' THEN 'true' WHEN 'off' THEN 'false' ELSE current_setting('synchronous_commit') END

UNION ALL
SELECT 21, 'wal',
    'fsync',
    'Гарантия записи на диск (fsync)',
    current_setting('fsync'),
    CASE current_setting('fsync') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 22, 'wal',
    'checkpoint_timeout',
    'Интервал контрольных точек',
    ((SELECT setting::int FROM pg_settings WHERE name = 'checkpoint_timeout') / 60)::text || ' мин',
    (SELECT setting FROM pg_settings WHERE name = 'checkpoint_timeout')

UNION ALL
SELECT 23, 'wal',
    'min_wal_size',
    'Мин. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('min_wal_size')))
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_bytes(current_setting('min_wal_size'))::text
        ELSE ''
    END

UNION ALL
SELECT 24, 'wal',
    'max_wal_size',
    'Макс. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('max_wal_size')))
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_bytes(current_setting('max_wal_size'))::text
        ELSE ''
    END

UNION ALL
SELECT 25, 'wal',
    'checkpoint_completion_target',
    'Полнота контрольных точек',
    current_setting('checkpoint_completion_target'),
    current_setting('checkpoint_completion_target')

UNION ALL
SELECT 26, 'wal',
    'wal_buffers',
    'Буферы журнала',
    pg_size_pretty(pg_size_bytes(current_setting('wal_buffers'))),
    pg_size_bytes(current_setting('wal_buffers'))::text

UNION ALL
SELECT 27, 'wal',
    'wal_level',
    'Уровень журналирования',
    current_setting('wal_level'),
    current_setting('wal_level')

UNION ALL

-- ============================================================================
-- ОПТИМИЗАЦИЯ ЗАПРОСОВ
-- ============================================================================

SELECT 30, 'planner',
    'random_page_cost',
    'Стоимость случайного чтения',
    current_setting('random_page_cost'),
    current_setting('random_page_cost')

UNION ALL
SELECT 31, 'planner',
    'join_collapse_limit',
    'Лимит оптимизации соединений',
    current_setting('join_collapse_limit'),
    current_setting('join_collapse_limit')

UNION ALL
SELECT 32, 'planner',
    'from_collapse_limit',
    'Лимит оптимизации подзапросов',
    current_setting('from_collapse_limit'),
    current_setting('from_collapse_limit')

UNION ALL
SELECT 33, 'planner',
    'geqo_threshold',
    'Порог генетического оптимизатора',
    current_setting('geqo_threshold'),
    current_setting('geqo_threshold')

UNION ALL
SELECT 34, 'planner',
    'default_statistics_target',
    'Детальность статистики',
    current_setting('default_statistics_target'),
    current_setting('default_statistics_target')

UNION ALL
SELECT 35, 'planner',
    'jit',
    'JIT-компиляция',
    COALESCE(current_setting('jit', true), 'n/a'),
    CASE COALESCE(current_setting('jit', true), '')
        WHEN 'on' THEN 'true' WHEN 'off' THEN 'false' ELSE ''
    END

UNION ALL
SELECT 36, 'planner',
    'max_parallel_workers_per_gather',
    'Параллельная обработка',
    current_setting('max_parallel_workers_per_gather'),
    current_setting('max_parallel_workers_per_gather')

UNION ALL
SELECT 37, 'planner',
    'seq_page_cost',
    'Стоимость последовательного чтения',
    current_setting('seq_page_cost'),
    current_setting('seq_page_cost')

UNION ALL
SELECT 38, 'planner',
    'cpu_tuple_cost',
    'Стоимость обработки строки',
    current_setting('cpu_tuple_cost'),
    current_setting('cpu_tuple_cost')

UNION ALL
SELECT 39, 'planner',
    'cpu_index_tuple_cost',
    'Стоимость обработки индексной строки',
    current_setting('cpu_index_tuple_cost'),
    current_setting('cpu_index_tuple_cost')

UNION ALL
SELECT 40, 'planner',
    'cpu_operator_cost',
    'Стоимость оператора',
    current_setting('cpu_operator_cost'),
    current_setting('cpu_operator_cost')

UNION ALL

-- ============================================================================
-- ПОДКЛЮЧЕНИЯ И СЕАНСЫ
-- ============================================================================

SELECT 43, 'connections',
    'max_connections',
    'Макс. подключений',
    current_setting('max_connections'),
    current_setting('max_connections')

UNION ALL
SELECT 44, 'connections',
    'idle_in_transaction_session_timeout',
    'Тайм-аут зависших транзакций',
    CASE
        WHEN current_setting('server_version_num')::int >= 90600
        THEN ((SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') / 1000)::text || ' сек'
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90600
        THEN (SELECT setting FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
        ELSE ''
    END

UNION ALL
SELECT 45, 'connections',
    'max_locks_per_transaction',
    'Лимит блокировок',
    current_setting('max_locks_per_transaction'),
    current_setting('max_locks_per_transaction')

UNION ALL

-- ============================================================================
-- АВТООЧИСТКА (AUTOVACUUM)
-- ============================================================================

SELECT 50, 'autovacuum',
    'autovacuum',
    'Автоочистка включена',
    current_setting('autovacuum'),
    CASE current_setting('autovacuum') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 51, 'autovacuum',
    'autovacuum_naptime',
    'Интервал проверки',
    (SELECT setting FROM pg_settings WHERE name = 'autovacuum_naptime') || ' сек',
    (SELECT setting FROM pg_settings WHERE name = 'autovacuum_naptime')

UNION ALL
SELECT 52, 'autovacuum',
    'autovacuum_max_workers',
    'Процессов автоочистки',
    current_setting('autovacuum_max_workers'),
    current_setting('autovacuum_max_workers')

UNION ALL
SELECT 53, 'autovacuum',
    'autovacuum_vacuum_cost_limit',
    'Лимит I/O автоочистки',
    current_setting('autovacuum_vacuum_cost_limit'),
    current_setting('autovacuum_vacuum_cost_limit')

UNION ALL

-- ============================================================================
-- ФОНОВАЯ ЗАПИСЬ
-- ============================================================================

SELECT 60, 'bgwriter',
    'bgwriter_delay',
    'Пауза фоновой записи',
    (SELECT setting FROM pg_settings WHERE name = 'bgwriter_delay') || ' мс',
    (SELECT setting FROM pg_settings WHERE name = 'bgwriter_delay')

UNION ALL
SELECT 61, 'bgwriter',
    'bgwriter_lru_maxpages',
    'Макс. страниц за цикл',
    current_setting('bgwriter_lru_maxpages'),
    current_setting('bgwriter_lru_maxpages')

UNION ALL
SELECT 62, 'bgwriter',
    'effective_io_concurrency',
    'Параллельное чтение с диска',
    current_setting('effective_io_concurrency'),
    current_setting('effective_io_concurrency')

UNION ALL

-- ============================================================================
-- СОВМЕСТИМОСТЬ С 1С
-- ============================================================================

SELECT 70, 'compat_1c',
    'standard_conforming_strings',
    'Режим обработки строк',
    current_setting('standard_conforming_strings'),
    CASE current_setting('standard_conforming_strings') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 71, 'compat_1c',
    'escape_string_warning',
    'Предупреждения экранирования',
    current_setting('escape_string_warning'),
    CASE current_setting('escape_string_warning') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 72, 'compat_1c',
    'row_security',
    'Политики безопасности строк',
    current_setting('row_security'),
    CASE current_setting('row_security') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL

-- ============================================================================
-- МОНИТОРИНГ И ЛОГИРОВАНИЕ
-- ============================================================================

SELECT 75, 'monitoring',
    'log_checkpoints',
    'Логирование контрольных точек',
    COALESCE(current_setting('log_checkpoints', true), 'n/a'),
    COALESCE(current_setting('log_checkpoints', true), '')

UNION ALL
SELECT 76, 'monitoring',
    'log_min_duration_statement',
    'Порог логирования медленных запросов',
    CASE
        WHEN (SELECT setting::bigint FROM pg_settings WHERE name = 'log_min_duration_statement') = -1 THEN 'off'
        WHEN (SELECT setting::bigint FROM pg_settings WHERE name = 'log_min_duration_statement') = 0 THEN 'all'
        ELSE (SELECT setting FROM pg_settings WHERE name = 'log_min_duration_statement') || ' ms'
    END,
    (SELECT setting FROM pg_settings WHERE name = 'log_min_duration_statement')

UNION ALL
SELECT 77, 'monitoring',
    'track_activity_query_size',
    'Размер буфера текста запроса',
    pg_size_pretty((SELECT setting::bigint FROM pg_settings WHERE name = 'track_activity_query_size')),
    (SELECT setting FROM pg_settings WHERE name = 'track_activity_query_size')

UNION ALL
SELECT 78, 'monitoring',
    'shared_preload_libraries',
    'Предзагруженные библиотеки',
    COALESCE(NULLIF(current_setting('shared_preload_libraries'), ''), '(none)'),
    current_setting('shared_preload_libraries')

UNION ALL
SELECT 79, 'monitoring',
    'auto_explain.log_min_duration',
    'auto_explain: порог логирования',
    COALESCE(current_setting('auto_explain.log_min_duration', true), 'not loaded'),
    COALESCE(current_setting('auto_explain.log_min_duration', true), '')

UNION ALL
SELECT 80, 'monitoring',
    'auto_explain.log_analyze',
    'auto_explain: EXPLAIN ANALYZE',
    COALESCE(current_setting('auto_explain.log_analyze', true), 'not loaded'),
    COALESCE(current_setting('auto_explain.log_analyze', true), '')

UNION ALL
SELECT 81, 'monitoring',
    'auto_explain.log_buffers',
    'auto_explain: статистика буферов',
    COALESCE(current_setting('auto_explain.log_buffers', true), 'not loaded'),
    COALESCE(current_setting('auto_explain.log_buffers', true), '')

UNION ALL
SELECT 82, 'monitoring',
    'log_statement',
    'Логирование SQL-команд',
    current_setting('log_statement'),
    current_setting('log_statement')

UNION ALL
SELECT 83, 'monitoring',
    'log_lock_waits',
    'Логирование ожиданий блокировок',
    current_setting('log_lock_waits'),
    CASE current_setting('log_lock_waits') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 84, 'monitoring',
    'log_temp_files',
    'Логирование временных файлов',
    CASE current_setting('log_temp_files')
        WHEN '-1' THEN 'off'
        WHEN '0' THEN 'all'
        ELSE current_setting('log_temp_files') || ' kB'
    END,
    current_setting('log_temp_files')

UNION ALL
SELECT 85, 'monitoring',
    'log_autovacuum_min_duration',
    'Логирование автоочистки',
    COALESCE(current_setting('log_autovacuum_min_duration', true), 'n/a'),
    COALESCE(current_setting('log_autovacuum_min_duration', true), '')

UNION ALL
SELECT 86, 'monitoring',
    'track_io_timing',
    'Замер времени I/O операций',
    current_setting('track_io_timing'),
    CASE current_setting('track_io_timing') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL

-- ============================================================================
-- РЕАЛЬНЫЕ МЕТРИКИ
-- ============================================================================

SELECT 170, 'metrics',
    '_metric_cache_hit_ratio',
    'Эффективность кэширования',
    CASE
        WHEN blks_hit + blks_read = 0 THEN 'нет данных'
        ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 2)::text || '%'
    END,
    CASE
        WHEN blks_hit + blks_read = 0 THEN ''
        ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 4)::text
    END
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

SELECT 171, 'metrics',
    '_metric_temp_files_count',
    'Временные файлы (количество)',
    temp_files::text,
    temp_files::text
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

SELECT 172, 'metrics',
    '_metric_temp_files_bytes',
    'Временные файлы (объём)',
    pg_size_pretty(temp_bytes),
    temp_bytes::text
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

-- Контрольные точки
SELECT 173, 'metrics',
    '_metric_checkpoints_timed',
    'Контрольные точки (по расписанию)',
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_timed'), 'n/a'),
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_timed'), '')
FROM pg_stat_bgwriter s

UNION ALL

SELECT 174, 'metrics',
    '_metric_checkpoints_req',
    'Контрольные точки (вынужденные)',
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_req'), 'n/a'),
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_req'), '')
FROM pg_stat_bgwriter s

UNION ALL

-- ============================================================================
-- РАЗДУТЫЕ ТАБЛИЦЫ (топ-10)
-- ============================================================================

SELECT bt."N", bt."Section", bt."Key", bt."Label", bt."Display", bt."Value"
FROM (
    SELECT
        200 + row_number() OVER (ORDER BY n_dead_tup DESC) AS "N",
        'bloat' AS "Section",
        '_bloat_' || schemaname || '.' || relname AS "Key",
        schemaname || '.' || relname AS "Label",
        pg_size_pretty(pg_total_relation_size(relid)) ||
            ' / мусор: ' ||
            CASE
                WHEN n_live_tup + n_dead_tup = 0 THEN '0%'
                ELSE round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)::text || '%'
            END ||
            ' / autovacuum: ' ||
            CASE
                WHEN last_autovacuum IS NULL THEN 'не выполнялся'
                ELSE to_char(last_autovacuum, 'DD.MM.YYYY HH24:MI')
            END AS "Display",
        json_build_object(
            'size_bytes', pg_total_relation_size(relid),
            'dead_ratio', CASE WHEN n_live_tup + n_dead_tup = 0 THEN 0
                ELSE round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) END,
            'dead_tuples', n_dead_tup,
            'live_tuples', n_live_tup
        )::text AS "Value"
    FROM pg_stat_user_tables
    WHERE n_live_tup + n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 10
) bt

UNION ALL

-- ============================================================================
-- ЗАВИСШИЕ СЕАНСЫ
-- ============================================================================

SELECT si."N", si."Section", si."Key", si."Label", si."Display", si."Value"
FROM (
    SELECT
        300 + row_number() OVER (ORDER BY state_change ASC) AS "N",
        'idle_sessions' AS "Section",
        '_idle_txn_' || pid::text AS "Key",
        COALESCE(usename, 'неизвестен') ||
            ' (' || COALESCE(client_addr::text, 'localhost') || ')' AS "Label",
        'простой: ' || to_char(now() - state_change, 'HH24 ч. MI мин.') AS "Display",
        EXTRACT(EPOCH FROM (now() - state_change))::bigint::text AS "Value"
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND pid <> pg_backend_pid()
    ORDER BY state_change ASC
) si

UNION ALL

SELECT 300, 'idle_sessions', '_idle_txn_none', 'Зависших сеансов нет', '', '0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()
)

UNION ALL

-- ============================================================================
-- РАСШИРЕНИЯ 1С (5.2)
-- ============================================================================

SELECT ex."N", ex."Section", ex."Key", ex."Label", ex."Display", ex."Value"
FROM (
    SELECT
        350 + row_number() OVER (ORDER BY name) AS "N",
        'extensions' AS "Section",
        '_ext_' || name AS "Key",
        name AS "Label",
        CASE
            WHEN installed_version IS NOT NULL THEN installed_version
            ELSE 'not installed'
        END AS "Display",
        json_build_object(
            'installed', installed_version IS NOT NULL,
            'installed_version', installed_version,
            'default_version', default_version
        )::text AS "Value"
    FROM pg_available_extensions
    WHERE name IN ('online_analyze', 'plantuner', 'mchar', 'fasttrun', 'fulleq',
                   'pg_stat_statements', 'auto_explain', 'pg_buffercache')
    ORDER BY name
) ex

UNION ALL

-- Если расширений 1С нет вообще (pg_available_extensions пустой для этих имён)
SELECT 350, 'extensions', '_ext_none', 'No 1C extensions found', '', '0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_available_extensions
    WHERE name IN ('online_analyze', 'plantuner', 'mchar', 'fasttrun', 'fulleq',
                   'pg_stat_statements', 'auto_explain', 'pg_buffercache')
)

UNION ALL

-- ============================================================================
-- ТОП-20 ТАБЛИЦ ПО РАЗМЕРУ (5.10)
-- ============================================================================

SELECT tt."N", tt."Section", tt."Key", tt."Label", tt."Display", tt."Value"
FROM (
    SELECT
        400 + row_number() OVER (ORDER BY pg_total_relation_size(oid) DESC) AS "N",
        'top_tables' AS "Section",
        '_table_' || relname AS "Key",
        relname AS "Label",
        pg_size_pretty(pg_total_relation_size(oid)) ||
            ' (data: ' || pg_size_pretty(pg_relation_size(oid)) ||
            ', idx: ' || pg_size_pretty(pg_indexes_size(oid)) || ')' AS "Display",
        json_build_object(
            'total_bytes', pg_total_relation_size(oid),
            'data_bytes', pg_relation_size(oid),
            'index_bytes', pg_indexes_size(oid),
            'rows_estimate', CASE WHEN reltuples > 0 THEN reltuples::bigint ELSE 0 END
        )::text AS "Value"
    FROM pg_class
    WHERE relkind = 'r'
      AND relnamespace = 'public'::regnamespace
    ORDER BY pg_total_relation_size(oid) DESC
    LIMIT 20
) tt

UNION ALL

-- ============================================================================
-- СВОДКА ПО СЕАНСАМ (5.4)
-- ============================================================================

SELECT 450, 'sessions',
    '_sessions_total',
    'Всего подключений',
    count(*)::text,
    count(*)::text
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()

UNION ALL
SELECT 451, 'sessions',
    '_sessions_active',
    'Активных запросов',
    count(*)::text,
    count(*)::text
FROM pg_stat_activity
WHERE state = 'active' AND pid <> pg_backend_pid()
  AND query NOT LIKE '%pg_stat_activity%'

UNION ALL
SELECT 452, 'sessions',
    '_sessions_idle',
    'Ожидающих (idle)',
    count(*)::text,
    count(*)::text
FROM pg_stat_activity
WHERE state = 'idle' AND pid <> pg_backend_pid()

UNION ALL
SELECT 453, 'sessions',
    '_sessions_idle_in_txn',
    'Зависших в транзакции',
    count(*)::text,
    count(*)::text
FROM pg_stat_activity
WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()

UNION ALL

-- ============================================================================
-- WAIT EVENTS (распределение ожиданий — 5.4)
-- ============================================================================

SELECT we."N", we."Section", we."Key", we."Label", we."Display", we."Value"
FROM (
    SELECT
        460 + row_number() OVER (ORDER BY count(*) DESC) AS "N",
        'wait_events' AS "Section",
        '_wait_' || COALESCE(wait_event_type, 'CPU') || '_' || COALESCE(wait_event, 'active') AS "Key",
        COALESCE(wait_event_type, 'CPU') || ': ' || COALESCE(wait_event, '(active on CPU)') AS "Label",
        count(*)::text || ' sessions' AS "Display",
        count(*)::text AS "Value"
    FROM pg_stat_activity
    WHERE state = 'active' AND pid <> pg_backend_pid()
      AND query NOT LIKE '%pg_stat_activity%'
    GROUP BY wait_event_type, wait_event
    ORDER BY count(*) DESC
) we

UNION ALL

-- Если нет активных сеансов — заглушка
SELECT 460, 'wait_events', '_wait_none', 'No active sessions', '', '0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE state = 'active' AND pid <> pg_backend_pid()
      AND query NOT LIKE '%pg_stat_activity%'
)

UNION ALL

-- ============================================================================
-- БЛОКИРОВКИ (5.5)
-- ============================================================================

SELECT lk."N", lk."Section", lk."Key", lk."Label", lk."Display", lk."Value"
FROM (
    SELECT
        470 + row_number() OVER (ORDER BY blocked.pid) AS "N",
        'locks' AS "Section",
        '_lock_' || blocked.pid::text AS "Key",
        'PID ' || blocked.pid || ' waits for PID ' || blocking.pid AS "Label",
        COALESCE(blocked.usename, '?') || ': ' || left(blocked.query, 80) AS "Display",
        json_build_object(
            'blocked_pid', blocked.pid,
            'blocking_pid', blocking.pid,
            'blocked_query', left(blocked.query, 200),
            'blocking_query', left(blocking.query, 200),
            'wait_duration_sec', EXTRACT(EPOCH FROM (now() - blocked.state_change))::int
        )::text AS "Value"
    FROM pg_stat_activity blocked
    JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
    JOIN pg_locks bk ON bk.locktype = bl.locktype
      AND bk.database IS NOT DISTINCT FROM bl.database
      AND bk.relation IS NOT DISTINCT FROM bl.relation
      AND bk.page IS NOT DISTINCT FROM bl.page
      AND bk.tuple IS NOT DISTINCT FROM bl.tuple
      AND bk.transactionid IS NOT DISTINCT FROM bl.transactionid
      AND bk.pid != bl.pid AND bk.granted
    JOIN pg_stat_activity blocking ON blocking.pid = bk.pid
    LIMIT 10
) lk

UNION ALL

-- Если блокировок нет — заглушка
SELECT 470, 'locks', '_lock_none', 'No locks detected', '', '0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_locks WHERE NOT granted
)

UNION ALL

-- ============================================================================
-- ВРЕМЕННЫЕ ТАБЛИЦЫ 1С (5.6)
-- ============================================================================

SELECT 480, 'temp_tables',
    '_temp_tables_count',
    'Временных таблиц в сеансах',
    count(*)::text,
    count(*)::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname LIKE 'pg_temp%' AND c.relkind = 'r'

UNION ALL

SELECT 481, 'temp_tables',
    '_temp_tables_size',
    'Суммарный размер temp-таблиц',
    pg_size_pretty(COALESCE(sum(pg_relation_size(c.oid)), 0)),
    COALESCE(sum(pg_relation_size(c.oid)), 0)::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname LIKE 'pg_temp%' AND c.relkind = 'r'

UNION ALL

-- ============================================================================
-- pg_stat_statements — топ-5 медленных запросов (если расширение загружено)
-- ============================================================================

SELECT ss."N", ss."Section", ss."Key", ss."Label", ss."Display", ss."Value"
FROM (
    SELECT
        490 + row_number() OVER (ORDER BY mean_exec_time DESC) AS "N",
        'slow_queries' AS "Section",
        '_slow_' || queryid::text AS "Key",
        left(query, 80) AS "Label",
        'avg: ' || round(mean_exec_time::numeric, 0) || ' ms, calls: ' || calls AS "Display",
        json_build_object(
            'queryid', queryid,
            'calls', calls,
            'mean_exec_time_ms', round(mean_exec_time::numeric, 0),
            'total_exec_time_ms', round(total_exec_time::numeric, 0),
            'query', left(query, 500)
        )::text AS "Value"
    FROM pg_stat_statements
    WHERE userid = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    ORDER BY mean_exec_time DESC
    LIMIT 5
) ss
WHERE EXISTS (
    SELECT 1 FROM pg_available_extensions
    WHERE name = 'pg_stat_statements' AND installed_version IS NOT NULL
)

UNION ALL

-- ============================================================================
-- ВСЕ ПАРАМЕТРЫ PostgreSQL (для сравнения серверов)
-- ============================================================================
-- Полный дамп pg_settings за исключением параметров, собранных выше с описаниями.
-- Позволяет сравнить конфигурацию эталонного и проблемного серверов.

SELECT
    ps."N", ps."Section", ps."Key", ps."Label", ps."Display", ps."Value"
FROM (
    SELECT
        500 + row_number() OVER (ORDER BY name) AS "N",
        'all_settings' AS "Section",
        name AS "Key",
        name AS "Label",
        CASE
            WHEN unit = '8kB' THEN pg_size_pretty(setting::bigint * 8192)
            WHEN unit = 'kB' THEN pg_size_pretty(setting::bigint * 1024)
            WHEN unit = 'ms' THEN setting || ' ms'
            WHEN unit = 's' THEN setting || ' s'
            WHEN unit = 'min' THEN setting || ' min'
            ELSE setting || COALESCE(' ' || unit, '')
        END AS "Display",
        setting AS "Value"
    FROM pg_settings
    WHERE name NOT IN (
        -- Уже собраны выше с подробными описаниями
        'shared_buffers', 'work_mem', 'effective_cache_size', 'maintenance_work_mem',
        'huge_pages', 'hash_mem_multiplier', 'temp_buffers',
        'synchronous_commit', 'fsync', 'checkpoint_timeout', 'min_wal_size', 'max_wal_size',
        'checkpoint_completion_target', 'wal_buffers', 'wal_level',
        'random_page_cost', 'seq_page_cost', 'cpu_tuple_cost', 'cpu_operator_cost',
        'cpu_index_tuple_cost', 'join_collapse_limit', 'from_collapse_limit',
        'geqo_threshold', 'default_statistics_target', 'jit', 'max_parallel_workers_per_gather',
        'max_connections', 'idle_in_transaction_session_timeout', 'max_locks_per_transaction',
        'autovacuum', 'autovacuum_naptime', 'autovacuum_max_workers', 'autovacuum_vacuum_cost_limit',
        'bgwriter_delay', 'bgwriter_lru_maxpages', 'effective_io_concurrency',
        'standard_conforming_strings', 'escape_string_warning', 'row_security',
        'log_checkpoints', 'log_min_duration_statement', 'track_activity_query_size',
        'shared_preload_libraries', 'log_statement', 'log_lock_waits', 'log_temp_files',
        'log_autovacuum_min_duration', 'track_io_timing'
    )
    ORDER BY name
) ps

) AS r("N", "Section", "Key", "Label", "Display", "Value")
ORDER BY r."N"
;

-- ============================================================================
-- КОНЕЦ СКРИПТА СБОРА ДАННЫХ v3.0
-- ============================================================================
