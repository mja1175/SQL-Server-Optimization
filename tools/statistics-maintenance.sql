USE DBA_Utilities;
GO

-- ==========================================================================
-- Table: dbo.StatisticsUpdate
-- ==========================================================================
IF OBJECT_ID('dbo.StatisticsUpdate', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[StatisticsUpdate](
        DatabaseName varchar(128) NOT NULL,
        SchemaName NVARCHAR(128) NOT NULL,
        TableName NVARCHAR(128) NOT NULL,
        StatisticName NVARCHAR(128) NOT NULL,
        LastUpdated DATETIME,
        DaysSinceUpdate INT,
        Modifications BIGINT,
        [RowCount] BIGINT,
        Percentage FLOAT,
        UpdateDate DATETIME DEFAULT GETDATE(),
        Outcome NVARCHAR(20),
        Run INT
    );
END
GO

-- ==========================================================================
-- Proc: dbo.sp_StatisticsMaintenance
-- ==========================================================================
-- Stored Procedure: sp_StatisticsMaintenance V2 (ROBUST VERSION)
-- Description: Check for stale statistics and optionally update them
--
-- V2 FIX: Complete redesign to process databases individually with validation
--         Eliminates silent failures from bulk collection approach
--
-- V2.1: Added @TableName filter to target one or more specific tables
--       instead of always scanning every user table in the database(s)
--
-- Statistics are considered STALE if ANY of these conditions are met:
--   1. AGE-BASED CRITERIA:
--      - No modifications AND older than 30 days, OR
--      - Has modifications AND older than 7 days
--   2. MODIFICATION RATE CRITERIA:
--      - Tables with 100,000+ rows: modification rate > 5%, OR
--      - Tables with < 100,000 rows: modification rate > 20%
--   3. EXCLUSIONS:
--      - CDC (Change Data Capture) schema is excluded
--      - Empty tables (0 rows) are excluded
--      - Only user tables are included (system tables excluded)
--
-- Usage: EXEC DBA_Utilities.dbo.sp_StatisticsMaintenance @DatabaseName = 'All', @Run = 0, @StatisticsSample = NULL, @TableName = NULL, @DetailOutput = 0

CREATE OR ALTER PROCEDURE dbo.sp_StatisticsMaintenance
    @DatabaseName NVARCHAR(MAX) = NULL,   -- NULL = all user databases, or comma-delimited list
    @Run BIT = 0,                         -- 0 = display only (default), 1 = execute updates
    @StatisticsSample DECIMAL(5,2) = NULL,-- NULL = no WITH clause (default), 100 = WITH FULLSCAN, 1-99.99 = WITH SAMPLE X PERCENT
    @TableName NVARCHAR(MAX) = NULL,      -- NULL = all tables (default), or comma-separated list e.g. 'Orders' or 'dbo.Orders,sales.Invoices'
    @DetailOutput BIT = 0                 -- 0 = minimal output (default - database progress only), 1 = detailed results
AS
BEGIN
    SET NOCOUNT ON;

    -- Ensure logging table exists
    IF OBJECT_ID('DBA_Utilities.dbo.StatisticsUpdate', 'U') IS NULL
    BEGIN
        CREATE TABLE DBA_Utilities.dbo.StatisticsUpdate (
            DatabaseName VARCHAR(128) NOT NULL,
            SchemaName NVARCHAR(128) NOT NULL,
            TableName NVARCHAR(128) NOT NULL,
            StatisticName NVARCHAR(128) NOT NULL,
            LastUpdated DATETIME,
            DaysSinceUpdate INT,
            Modifications BIGINT,
            [RowCount] BIGINT,
            Percentage FLOAT,
            UpdateDate DATETIME DEFAULT GETDATE(),
            Outcome NVARCHAR(20),
            Run INT
        );
    END

    -- Purge records older than 30 days
    DELETE FROM DBA_Utilities.dbo.StatisticsUpdate WHERE UpdateDate < DATEADD(DAY, -30, GETDATE());

    -- Get next run number
    DECLARE @RunNumber INT;
    SELECT @RunNumber = ISNULL(MAX(Run), 0) + 1 FROM DBA_Utilities.dbo.StatisticsUpdate;

    -- Parse @TableName into a filter table (NULL/empty = no filter, all tables scanned)
    CREATE TABLE #TableFilter (SchemaName NVARCHAR(128) NULL, TableName NVARCHAR(128) NOT NULL);

    IF @TableName IS NOT NULL AND LTRIM(RTRIM(@TableName)) <> ''
    BEGIN
        INSERT INTO #TableFilter (SchemaName, TableName)
        SELECT
            CASE WHEN CHARINDEX('.', v) > 0 THEN LTRIM(RTRIM(LEFT(v, CHARINDEX('.', v) - 1))) ELSE NULL END,
            CASE WHEN CHARINDEX('.', v) > 0 THEN LTRIM(RTRIM(SUBSTRING(v, CHARINDEX('.', v) + 1, LEN(v)))) ELSE LTRIM(RTRIM(v)) END
        FROM (SELECT LTRIM(RTRIM(value)) AS v FROM STRING_SPLIT(@TableName, ',')) AS x
        WHERE v <> '';
    END

    DECLARE @TableFilterCount INT = (SELECT COUNT(*) FROM #TableFilter);

    DECLARE @StartTime DATETIME = GETDATE();

    IF @DetailOutput = 1
    BEGIN
        PRINT '=============================================='
        PRINT 'STALE STATISTICS CHECKER V2'
        PRINT '=============================================='
        PRINT 'Database: ' + ISNULL(@DatabaseName, 'All user databases')
        PRINT 'Run Mode: ' + CASE WHEN @Run = 1 THEN 'EXECUTE UPDATES' ELSE 'DISPLAY ONLY' END
        PRINT 'Sampling: ' + CASE
            WHEN @StatisticsSample IS NULL THEN 'Default (no WITH clause)'
            WHEN @StatisticsSample = 100 THEN 'FULLSCAN'
            ELSE CAST(@StatisticsSample AS VARCHAR(10)) + '% SAMPLE'
        END
        PRINT 'Table Filter: ' + CASE WHEN @TableFilterCount = 0 THEN 'None (all tables)' ELSE CAST(@TableFilterCount AS VARCHAR(10)) + ' table(s): ' + @TableName END
        PRINT 'Started: ' + CONVERT(VARCHAR(30), @StartTime, 120)
    END

    -- Build WITH clause based on @StatisticsSample parameter
    DECLARE @WithClause NVARCHAR(50);
    IF @StatisticsSample IS NULL
        SET @WithClause = '';
    ELSE IF @StatisticsSample = 100
        SET @WithClause = ' WITH FULLSCAN';
    ELSE
        SET @WithClause = ' WITH SAMPLE ' + CAST(@StatisticsSample AS VARCHAR(10)) + ' PERCENT';

    -- Get list of databases based on @DatabaseName parameter
    CREATE TABLE #DatabaseList (
        DatabaseName NVARCHAR(128),
        Processed BIT DEFAULT 0,
        StatCount INT DEFAULT 0,
        ProcessedAt DATETIME NULL
    );

    IF @DatabaseName IS NULL
    BEGIN
        INSERT INTO #DatabaseList (DatabaseName)
        SELECT d.name
        FROM sys.databases d
        WHERE d.state_desc = 'ONLINE'
          AND d.database_id > 4
        ORDER BY d.name;
    END
    ELSE IF @DatabaseName LIKE '%[%]%'
    BEGIN
        INSERT INTO #DatabaseList (DatabaseName)
        SELECT d.name
        FROM sys.databases d
        WHERE d.state_desc = 'ONLINE'
          AND d.name LIKE @DatabaseName
        ORDER BY d.name;
    END
    ELSE
    BEGIN
        INSERT INTO #DatabaseList (DatabaseName)
        SELECT d.name
        FROM sys.databases d
        INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
        WHERE d.state_desc = 'ONLINE'
        ORDER BY d.name;
    END

    DECLARE @ExpectedDBCount INT = (SELECT COUNT(*) FROM #DatabaseList);
    DECLARE @TotalStatsCount INT = 0;
    DECLARE @TotalExecuted INT = 0;
    DECLARE @TotalSuccess INT = 0;
    DECLARE @TotalErrors INT = 0;

    -- V2 FIX: Process each database individually with validation
    DECLARE @DBName NVARCHAR(128);
    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @DBCounter INT = 0;
    DECLARE @DBStartTime DATETIME;

    IF @DetailOutput = 1
    BEGIN
        PRINT ''
        PRINT 'Databases: ' + CAST(@ExpectedDBCount AS VARCHAR(10));
        PRINT ''
        PRINT '=============================================='
        PRINT 'RESULTS'
        PRINT '=============================================='
        PRINT ''
    END

    DECLARE db_cursor CURSOR FOR
        SELECT DatabaseName FROM #DatabaseList ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DBName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @DBCounter = @DBCounter + 1;
        SET @DBStartTime = GETDATE();

        -- V2: Create per-database temp table
        IF OBJECT_ID('tempdb..#CurrentDBStats') IS NOT NULL
            DROP TABLE #CurrentDBStats;

        CREATE TABLE #CurrentDBStats (
            SchemaName NVARCHAR(128),
            TableName NVARCHAR(128),
            StatisticName NVARCHAR(128),
            LastUpdated DATETIME,
            DaysSinceUpdate INT,
            Modifications BIGINT,
            [RowCount] BIGINT,
            Percentage FLOAT
        );

        -- Collect statistics for this database only
        SET @SQL = 'USE [' + @DBName + ']' + CHAR(10) + N'
        INSERT INTO #CurrentDBStats (SchemaName, TableName, StatisticName, LastUpdated, DaysSinceUpdate, Modifications, [RowCount], Percentage)
        SELECT
            OBJECT_SCHEMA_NAME(s.object_id) AS SchemaName,
            OBJECT_NAME(s.object_id) AS TableName,
            s.name AS StatisticName,
            sp.last_updated AS LastUpdated,
            DATEDIFF(DAY, sp.last_updated, GETDATE()) AS DaysSinceUpdate,
            sp.modification_counter AS Modifications,
            sp.rows AS [RowCount],
            (CAST(sp.modification_counter AS FLOAT) / NULLIF(sp.rows, 0)) * 100 AS Percentage
        FROM sys.stats s
        CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
        WHERE OBJECTPROPERTY(s.object_id, ''IsUserTable'') = 1
          AND (
              (
                  sp.modification_counter = 0 AND DATEDIFF(DAY, sp.last_updated, GETDATE()) > 30
                  OR
                  sp.modification_counter > 0 AND DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7
              )
              OR (
                  (sp.rows >= 100000 AND CAST(sp.modification_counter AS FLOAT) / NULLIF(sp.rows, 0) * 100 > 5)
                  OR
                  (CAST(sp.modification_counter AS FLOAT) / NULLIF(sp.rows, 0) * 100 > 20)
              )
          )
          AND OBJECT_SCHEMA_NAME(s.object_id) <> ''cdc''
          AND sp.rows > 0
          AND (
              NOT EXISTS (SELECT 1 FROM #TableFilter)
              OR EXISTS (
                  SELECT 1 FROM #TableFilter tf
                  WHERE tf.TableName = OBJECT_NAME(s.object_id)
                    AND (tf.SchemaName IS NULL OR tf.SchemaName = OBJECT_SCHEMA_NAME(s.object_id))
              )
          );
        ';

        DECLARE @DBStatCount INT = 0;
        DECLARE @DBSuccess INT = 0;
        DECLARE @DBErrors INT = 0;

        BEGIN TRY
            EXEC sp_executesql @SQL;
            SELECT @DBStatCount = COUNT(*) FROM #CurrentDBStats;

            UPDATE #DatabaseList
            SET Processed = 1,
                StatCount = @DBStatCount,
                ProcessedAt = GETDATE()
            WHERE DatabaseName = @DBName;

            SET @TotalStatsCount = @TotalStatsCount + @DBStatCount;

            -- Process statistics for this database
            IF @DBStatCount > 0
            BEGIN
                DECLARE @SchemaName NVARCHAR(128);
                DECLARE @StatTableName NVARCHAR(128);
                DECLARE @StatName NVARCHAR(128);
                DECLARE @LastUpdate DATETIME;
                DECLARE @Mods BIGINT;
                DECLARE @Rows BIGINT;
                DECLARE @Pct FLOAT;
                DECLARE @Cmd NVARCHAR(4000);
                DECLARE @CurrentTable NVARCHAR(256) = '';

                DECLARE stats_cursor CURSOR LOCAL FAST_FORWARD FOR
                    SELECT SchemaName, TableName, StatisticName, LastUpdated, Modifications, [RowCount], Percentage
                    FROM #CurrentDBStats
                    ORDER BY TableName, StatisticName;

                OPEN stats_cursor;
                FETCH NEXT FROM stats_cursor INTO @SchemaName, @StatTableName, @StatName, @LastUpdate, @Mods, @Rows, @Pct;

                IF @DetailOutput = 1
                BEGIN
                    PRINT 'Database: ' + @DBName;
                    PRINT '';
                END

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @Cmd = 'UPDATE STATISTICS [' + @DBName + '].[' + @SchemaName + '].[' + @StatTableName + '] [' + @StatName + ']' + @WithClause + ';';

                    IF @DetailOutput = 1
                    BEGIN
                        IF @CurrentTable <> @SchemaName + '.' + @StatTableName
                        BEGIN
                            IF @CurrentTable <> ''
                                PRINT '';
                            PRINT 'Table: ' + @SchemaName + '.' + @StatTableName;
                            SET @CurrentTable = @SchemaName + '.' + @StatTableName;
                        END

                        PRINT '  Statistic: ' + @StatName;
                        PRINT '  Last Updated: ' + CONVERT(VARCHAR(30), @LastUpdate, 120);
                        PRINT '  Modifications: ' + CAST(@Mods AS VARCHAR(20));
                        PRINT '  Rows: ' + CAST(@Rows AS VARCHAR(20));
                        PRINT '  Percent: ' + CAST(CAST(@Pct AS DECIMAL(10,2)) AS VARCHAR(20)) + '%';
                        PRINT '  Command: ' + @Cmd;
                    END

                    -- Execute if @Run = 1
                    IF @Run = 1
                    BEGIN
                        SET @TotalExecuted = @TotalExecuted + 1;

                        BEGIN TRY
                            EXEC sp_executesql @Cmd;
                            SET @DBSuccess = @DBSuccess + 1;
                            SET @TotalSuccess = @TotalSuccess + 1;

                            INSERT INTO DBA_Utilities.dbo.StatisticsUpdate
                                (DatabaseName, SchemaName, TableName, StatisticName, LastUpdated, DaysSinceUpdate, Modifications, [RowCount], Percentage, Outcome, Run)
                            VALUES
                                (@DBName, @SchemaName, @StatTableName, @StatName, @LastUpdate,
                                 DATEDIFF(DAY, @LastUpdate, GETDATE()), @Mods, @Rows, @Pct, N'Success', @RunNumber);

                            IF @DetailOutput = 1
                                PRINT '  Outcome: Success';
                        END TRY
                        BEGIN CATCH
                            SET @DBErrors = @DBErrors + 1;
                            SET @TotalErrors = @TotalErrors + 1;

                            INSERT INTO DBA_Utilities.dbo.StatisticsUpdate
                                (DatabaseName, SchemaName, TableName, StatisticName, LastUpdated, DaysSinceUpdate, Modifications, [RowCount], Percentage, Outcome, Run)
                            VALUES
                                (@DBName, @SchemaName, @StatTableName, @StatName, @LastUpdate,
                                 DATEDIFF(DAY, @LastUpdate, GETDATE()), @Mods, @Rows, @Pct, N'Failure', @RunNumber);

                            IF @DetailOutput = 1
                                PRINT '  Outcome: Failure - ' + ERROR_MESSAGE();
                        END CATCH
                    END

                    IF @DetailOutput = 1
                        PRINT '';

                    FETCH NEXT FROM stats_cursor INTO @SchemaName, @StatTableName, @StatName, @LastUpdate, @Mods, @Rows, @Pct;
                END

                CLOSE stats_cursor;
                DEALLOCATE stats_cursor;

                IF @DetailOutput = 1
                    PRINT '';
            END

            IF @DetailOutput = 1
            BEGIN
                DECLARE @DBDuration INT = DATEDIFF(SECOND, @DBStartTime, GETDATE());
                PRINT 'Database ' + CAST(@DBCounter AS VARCHAR(10)) + ' of ' + CAST(@ExpectedDBCount AS VARCHAR(10)) +
                      ': ' + @DBName + ' - ' + CAST(@DBStatCount AS VARCHAR(10)) + ' statistics - ' +
                      CAST(@DBDuration AS VARCHAR(10)) + ' seconds';
            END

        END TRY
        BEGIN CATCH
            PRINT 'WARNING: Could not process database [' + @DBName + '] - ' + ERROR_MESSAGE();
        END CATCH

        -- Cleanup per-database temp table
        IF OBJECT_ID('tempdb..#CurrentDBStats') IS NOT NULL
            DROP TABLE #CurrentDBStats;

        FETCH NEXT FROM db_cursor INTO @DBName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- V2: Validation
    DECLARE @DBsProcessed INT = (SELECT COUNT(*) FROM #DatabaseList WHERE Processed = 1);

    IF @DBsProcessed < @ExpectedDBCount
    BEGIN
        PRINT ''
        PRINT '***** WARNING *****'
        PRINT 'Expected to process ' + CAST(@ExpectedDBCount AS VARCHAR(10)) + ' databases'
        PRINT 'Actually processed ' + CAST(@DBsProcessed AS VARCHAR(10)) + ' databases'
        PRINT 'Missing ' + CAST(@ExpectedDBCount - @DBsProcessed AS VARCHAR(10)) + ' databases!'
        PRINT ''
        PRINT 'Databases NOT processed:'
        SELECT DatabaseName FROM #DatabaseList WHERE Processed = 0 ORDER BY DatabaseName;
        PRINT ''
    END

    -- Summary at the end
    DECLARE @EndTime DATETIME = GETDATE();
    DECLARE @TotalDuration INT = DATEDIFF(SECOND, @StartTime, @EndTime);

    IF @DetailOutput = 1
    BEGIN
        PRINT ''
        PRINT '=============================================='
        PRINT 'SUMMARY'
        PRINT '=============================================='
        PRINT 'Expected databases: ' + CAST(@ExpectedDBCount AS VARCHAR(10));
        PRINT 'Processed databases: ' + CAST(@DBsProcessed AS VARCHAR(10));
        PRINT 'Total stale statistics found: ' + CAST(@TotalStatsCount AS VARCHAR(10));
        IF @Run = 1
        BEGIN
            PRINT 'Total commands executed: ' + CAST(@TotalExecuted AS VARCHAR(10));
            PRINT 'Successful: ' + CAST(@TotalSuccess AS VARCHAR(10));
            PRINT 'Errors: ' + CAST(@TotalErrors AS VARCHAR(10));
        END
        PRINT 'Total duration: ' + CAST(@TotalDuration AS VARCHAR(10)) + ' seconds';
        PRINT 'Finished: ' + CONVERT(VARCHAR(30), @EndTime, 120);
        PRINT '=============================================='
    END

    -- Cleanup
    DROP TABLE #DatabaseList;
    DROP TABLE #TableFilter;

    SET NOCOUNT OFF;
END
GO
