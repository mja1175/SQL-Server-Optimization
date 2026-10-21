/*
    SQL Server Optimization Suite
    Default Database: DBA_Utilities

    To install in a different database, find and replace all instances of
    "DBA_Utilities" with your database name before running this script.
*/
USE DBA_Utilities;
GO

-- ==========================================================================
-- Table: optimize.IndexMaintenanceHistory
-- ==========================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'optimize')
    EXEC('CREATE SCHEMA optimize');
GO

IF OBJECT_ID('optimize.IndexMaintenanceHistory', 'U') IS NULL
BEGIN
    CREATE TABLE optimize.IndexMaintenanceHistory (
        Id              BIGINT IDENTITY(1,1) NOT NULL,
        RunId           INT              NOT NULL,
        ServerName      NVARCHAR(128)    NOT NULL CONSTRAINT DF_IMH_ServerName DEFAULT @@SERVERNAME,
        DatabaseName    NVARCHAR(128)    NOT NULL,
        SchemaName      NVARCHAR(128)    NOT NULL,
        TableName       NVARCHAR(128)    NOT NULL,
        IndexName       NVARCHAR(128)    NOT NULL,
        IndexType       VARCHAR(20)      NOT NULL,
        PartitionNumber INT              NOT NULL DEFAULT 1,
        FragmentationPct DECIMAL(5,2)    NOT NULL,
        PageCount       BIGINT           NOT NULL,
        SizeMB          DECIMAL(10,2)    NOT NULL,
        Action          VARCHAR(20)      NOT NULL,
        ActionReason    VARCHAR(200)     NULL,
        CommandExecuted NVARCHAR(MAX)    NULL,
        StartTime       DATETIME2(3)     NULL,
        EndTime         DATETIME2(3)     NULL,
        DurationSeconds AS DATEDIFF(SECOND, StartTime, EndTime),
        Status          VARCHAR(20)      NOT NULL CONSTRAINT DF_IMH_Status DEFAULT 'Pending',
        ErrorMessage    NVARCHAR(MAX)    NULL,
        CreatedDate     DATETIME2(3)     NOT NULL CONSTRAINT DF_IMH_CreatedDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_IndexMaintenanceHistory PRIMARY KEY CLUSTERED (Id DESC) WITH (FILLFACTOR = 100)
    );
END
GO

-- ==========================================================================
-- Proc: optimize.sp_IndexMaintenance
-- ==========================================================================

CREATE OR ALTER PROCEDURE optimize.sp_IndexMaintenance
    @Databases          NVARCHAR(MAX)   = NULL,         -- NULL = all user DBs. Supports Ola Hallengren-style syntax
    @TableName          NVARCHAR(MAX)   = NULL,         -- NULL = all tables. CSV with optional schema prefix (dbo.MyTable)
    @ReorgThreshold     DECIMAL(5,2)    = 10.0,         -- reorganize at or above this fragmentation %
    @RebuildThreshold   DECIMAL(5,2)    = NULL,         -- NULL = auto (Enterprise: 10%, Standard: 30%)
    @MinPageCount       INT             = 1000,         -- skip indexes smaller than this (< 8 MB)
    @MaxIndexSizeMB     INT             = NULL,         -- NULL = no limit. Skip indexes larger than this
    @MaxDOP             INT             = NULL,         -- NULL = server default
    @TimeLimit          INT             = 18000,        -- seconds. 18000 = 5 hours. 0 = no limit
    @Execute            BIT             = 0,            -- 0 = dry run (show what would happen). 1 = execute maintenance
    @LOBCompaction      BIT             = 1,            -- LOB_COMPACTION = ON for REORGANIZE operations
    @SortBy             VARCHAR(20)     = 'FRAGMENTATION' -- FRAGMENTATION (default) or SIZE
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------------------------
    -- Edition detection
    ---------------------------------------------------------------------------
    DECLARE @IsEnterprise BIT = CASE
        WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 3 THEN 1
        ELSE 0
    END;

    IF @RebuildThreshold IS NULL
        SET @RebuildThreshold = CASE WHEN @IsEnterprise = 1 THEN @ReorgThreshold ELSE 30.0 END;

    IF @RebuildThreshold < @ReorgThreshold
        SET @RebuildThreshold = @ReorgThreshold;

    ---------------------------------------------------------------------------
    -- Run tracking
    ---------------------------------------------------------------------------
    DECLARE @RunId INT;
    SELECT @RunId = ISNULL(MAX(RunId), 0) + 1 FROM optimize.IndexMaintenanceHistory;

    DELETE FROM optimize.IndexMaintenanceHistory WHERE CreatedDate < DATEADD(DAY, -90, SYSDATETIME());

    DECLARE @RunStartTime DATETIME2(3) = SYSDATETIME();
    DECLARE @TimeLimitEnd DATETIME2(3) = CASE
        WHEN @TimeLimit > 0 THEN DATEADD(SECOND, @TimeLimit, @RunStartTime)
        ELSE '9999-12-31'
    END;
    DECLARE @TimeLimitReached BIT = 0;

    ---------------------------------------------------------------------------
    -- Build database list (standard 3-way parsing)
    ---------------------------------------------------------------------------
    CREATE TABLE #DatabaseList (DatabaseName NVARCHAR(128));

    INSERT INTO #DatabaseList (DatabaseName)
    SELECT f.DatabaseName FROM optimize.fn_GetDatabases(@Databases) f
    INNER JOIN sys.databases d ON f.DatabaseName = d.name
    WHERE d.is_read_only = 0;

    DECLARE @DBCount INT = (SELECT COUNT(*) FROM #DatabaseList);

    ---------------------------------------------------------------------------
    -- Parse @TableName filter
    ---------------------------------------------------------------------------
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

    ---------------------------------------------------------------------------
    -- Header
    ---------------------------------------------------------------------------
    DECLARE @Msg NVARCHAR(500);
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    SET @Msg = 'INDEX MAINTENANCE' + CASE WHEN @Execute = 0 THEN ' - DRY RUN' ELSE '' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Server: ' + @@SERVERNAME;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Edition: ' + CASE WHEN @IsEnterprise = 1 THEN 'Enterprise (ONLINE rebuilds available)' ELSE 'Standard Edition' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Reorganize: >= ' + CAST(@ReorgThreshold AS VARCHAR(10)) + '%%   Rebuild: >= ' + CAST(@RebuildThreshold AS VARCHAR(10)) + '%%';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Min Pages: ' + FORMAT(@MinPageCount, 'N0') + ' (' + CAST(CAST(@MinPageCount * 8.0 / 1024 AS DECIMAL(10,1)) AS VARCHAR(20)) + ' MB)';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    IF @MaxIndexSizeMB IS NOT NULL
    BEGIN
        SET @Msg = 'Max Index Size: ' + FORMAT(@MaxIndexSizeMB, 'N0') + ' MB';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TimeLimit > 0
    BEGIN
        SET @Msg = 'Time Limit: ' + CAST(@TimeLimit / 3600 AS VARCHAR(5)) + 'h ' + CAST((@TimeLimit % 3600) / 60 AS VARCHAR(5)) + 'm';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    SET @Msg = 'Databases: ' + CAST(@DBCount AS VARCHAR(10));
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- Counters
    ---------------------------------------------------------------------------
    DECLARE @TotalReorg INT = 0, @TotalRebuildOnline INT = 0, @TotalRebuildOffline INT = 0;
    DECLARE @TotalFailed INT = 0, @TotalTimeLimited INT = 0, @DBsProcessed INT = 0, @DBsWithWork INT = 0;
    DECLARE @TotalReorgMB DECIMAL(12,2) = 0, @TotalRebuildMB DECIMAL(12,2) = 0;

    ---------------------------------------------------------------------------
    -- Database loop
    ---------------------------------------------------------------------------
    DECLARE @DBName NVARCHAR(128);
    DECLARE @SQL NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM #DatabaseList ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DBName;

    WHILE @@FETCH_STATUS = 0 AND @TimeLimitReached = 0
    BEGIN
        IF @TimeLimit > 0 AND SYSDATETIME() >= @TimeLimitEnd
        BEGIN
            SET @TimeLimitReached = 1;
            BREAK;
        END

        SET @DBsProcessed = @DBsProcessed + 1;

        -----------------------------------------------------------------------
        -- Scan fragmentation for this database
        -----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#FragData') IS NOT NULL DROP TABLE #FragData;

        CREATE TABLE #FragData (
            RowId           INT IDENTITY(1,1),
            SchemaName      NVARCHAR(128),
            TableName       NVARCHAR(128),
            IndexName       NVARCHAR(128),
            IndexId         INT,
            IndexType       VARCHAR(20),
            PartitionNumber INT,
            FragmentationPct DECIMAL(5,2),
            PageCount       BIGINT,
            SizeMB          DECIMAL(10,2),
            Processed       BIT DEFAULT 0
        );

        SET @SQL = N'USE ' + QUOTENAME(@DBName) + N';

        INSERT INTO #FragData (SchemaName, TableName, IndexName, IndexId, IndexType, PartitionNumber, FragmentationPct, PageCount, SizeMB)
        SELECT
            s.name,
            t.name,
            i.name,
            i.index_id,
            CASE i.type WHEN 1 THEN ''CLUSTERED'' WHEN 2 THEN ''NONCLUSTERED'' END,
            ps.partition_number,
            CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,2)),
            ps.page_count,
            CAST(ps.page_count * 8.0 / 1024 AS DECIMAL(10,2))
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') ps
        INNER JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
        INNER JOIN sys.tables t ON i.object_id = t.object_id
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE ps.index_id > 0
          AND i.type IN (1, 2)
          AND ps.alloc_unit_type_desc = ''IN_ROW_DATA''
          AND ps.page_count >= @pMinPageCount
          AND ps.avg_fragmentation_in_percent >= @pReorgThreshold
          AND i.is_disabled = 0
          AND i.is_hypothetical = 0
          AND s.name <> ''cdc''
          AND (
              NOT EXISTS (SELECT 1 FROM #TableFilter)
              OR EXISTS (
                  SELECT 1 FROM #TableFilter tf
                  WHERE tf.TableName = t.name
                    AND (tf.SchemaName IS NULL OR tf.SchemaName = s.name)
              )
          )';

        IF @MaxIndexSizeMB IS NOT NULL
            SET @SQL = @SQL + N'
          AND ps.page_count * 8.0 / 1024 <= @pMaxIndexSizeMB';

        SET @SQL = @SQL + N';';

        BEGIN TRY
            EXEC sp_executesql @SQL,
                N'@pMinPageCount INT, @pReorgThreshold DECIMAL(5,2), @pMaxIndexSizeMB INT',
                @pMinPageCount = @MinPageCount,
                @pReorgThreshold = @ReorgThreshold,
                @pMaxIndexSizeMB = @MaxIndexSizeMB;
        END TRY
        BEGIN CATCH
            SET @Msg = '  ERROR scanning ' + @DBName + ': ' + ERROR_MESSAGE();
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            INSERT INTO optimize.IndexMaintenanceHistory
                (RunId, DatabaseName, SchemaName, TableName, IndexName, IndexType, FragmentationPct, PageCount, SizeMB, Action, ActionReason, Status, ErrorMessage)
            VALUES
                (@RunId, @DBName, '-', '-', '-', '-', 0, 0, 0, 'SCAN', 'Fragmentation scan failed', 'Failed', ERROR_MESSAGE());

            SET @TotalFailed = @TotalFailed + 1;
            FETCH NEXT FROM db_cursor INTO @DBName;
            CONTINUE;
        END CATCH

        DECLARE @IdxCount INT = (SELECT COUNT(*) FROM #FragData);

        IF @IdxCount = 0
        BEGIN
            FETCH NEXT FROM db_cursor INTO @DBName;
            CONTINUE;
        END

        SET @DBsWithWork = @DBsWithWork + 1;

        DECLARE @DBReorgMB DECIMAL(10,2) = 0, @DBRebuildMB DECIMAL(10,2) = 0;
        DECLARE @DBReorg INT = 0, @DBRebuild INT = 0;

        SET @Msg = '  ' + @DBName + ': ' + CAST(@IdxCount AS VARCHAR(10)) + ' fragmented index(es)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        -----------------------------------------------------------------------
        -- Index loop
        -----------------------------------------------------------------------
        DECLARE @RowId INT, @Schema NVARCHAR(128), @Table NVARCHAR(128), @Index NVARCHAR(128);
        DECLARE @IdxId INT, @IdxType VARCHAR(20), @Partition INT;
        DECLARE @Frag DECIMAL(5,2), @Pages BIGINT, @Size DECIMAL(10,2);

        DECLARE @Action VARCHAR(20), @Reason VARCHAR(200), @Cmd NVARCHAR(MAX);
        DECLARE @OpStart DATETIME2(3), @OpEnd DATETIME2(3);
        DECLARE @Succeeded BIT, @ErrorMsg NVARCHAR(MAX);
        DECLARE @PartitionClause NVARCHAR(50);
        DECLARE @IsPartitioned BIT;

        DECLARE idx_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT RowId, SchemaName, TableName, IndexName, IndexId, IndexType, PartitionNumber,
                   FragmentationPct, PageCount, SizeMB
            FROM #FragData
            ORDER BY
                CASE WHEN @SortBy = 'SIZE' THEN PageCount ELSE 0 END DESC,
                FragmentationPct DESC;

        OPEN idx_cursor;
        FETCH NEXT FROM idx_cursor INTO @RowId, @Schema, @Table, @Index, @IdxId, @IdxType, @Partition, @Frag, @Pages, @Size;

        WHILE @@FETCH_STATUS = 0 AND @TimeLimitReached = 0
        BEGIN
            IF @TimeLimit > 0 AND SYSDATETIME() >= @TimeLimitEnd
            BEGIN
                SET @TimeLimitReached = 1;
                BREAK;
            END

            -------------------------------------------------------------------
            -- Detect partitioned index
            -------------------------------------------------------------------
            SET @IsPartitioned = CASE
                WHEN EXISTS (SELECT 1 FROM #FragData f2 WHERE f2.IndexName = @Index AND f2.SchemaName = @Schema AND f2.TableName = @Table AND f2.IndexId = @IdxId AND f2.PartitionNumber <> @Partition)
                THEN 1 ELSE 0
            END;

            SET @PartitionClause = CASE WHEN @IsPartitioned = 1 THEN ' PARTITION = ' + CAST(@Partition AS NVARCHAR(10)) ELSE '' END;

            -------------------------------------------------------------------
            -- Determine action
            -------------------------------------------------------------------
            IF @Frag >= @RebuildThreshold
            BEGIN
                IF @IsEnterprise = 1
                BEGIN
                    SET @Action = 'REBUILD_ONLINE';
                    SET @Reason = 'Frag ' + CAST(@Frag AS VARCHAR(10)) + '% >= ' + CAST(@RebuildThreshold AS VARCHAR(10)) + '% (ONLINE)';
                END
                ELSE
                BEGIN
                    SET @Action = 'REBUILD_OFFLINE';
                    SET @Reason = 'Frag ' + CAST(@Frag AS VARCHAR(10)) + '% >= ' + CAST(@RebuildThreshold AS VARCHAR(10)) + '% (OFFLINE)';
                END
            END
            ELSE
            BEGIN
                SET @Action = 'REORGANIZE';
                SET @Reason = 'Frag ' + CAST(@Frag AS VARCHAR(10)) + '% >= ' + CAST(@ReorgThreshold AS VARCHAR(10)) + '%';
            END

            -------------------------------------------------------------------
            -- Build command
            -------------------------------------------------------------------
            IF @Action = 'REORGANIZE'
            BEGIN
                SET @Cmd = 'ALTER INDEX ' + QUOTENAME(@Index) + ' ON ' + QUOTENAME(@DBName) + '.' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ' REORGANIZE' + @PartitionClause;
                IF @LOBCompaction = 0
                    SET @Cmd = @Cmd + ' WITH (LOB_COMPACTION = OFF)';
            END
            ELSE IF @Action = 'REBUILD_ONLINE'
            BEGIN
                SET @Cmd = 'ALTER INDEX ' + QUOTENAME(@Index) + ' ON ' + QUOTENAME(@DBName) + '.' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ' REBUILD' + @PartitionClause + ' WITH (ONLINE = ON';
                IF @MaxDOP IS NOT NULL
                    SET @Cmd = @Cmd + ', MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(5));
                SET @Cmd = @Cmd + ')';
            END
            ELSE
            BEGIN
                SET @Cmd = 'ALTER INDEX ' + QUOTENAME(@Index) + ' ON ' + QUOTENAME(@DBName) + '.' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ' REBUILD' + @PartitionClause;
                IF @MaxDOP IS NOT NULL
                    SET @Cmd = @Cmd + ' WITH (MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(5)) + ')';
            END

            -------------------------------------------------------------------
            -- Execute or dry-run
            -------------------------------------------------------------------
            SET @Succeeded = 0;
            SET @ErrorMsg = NULL;
            SET @OpStart = SYSDATETIME();

            IF @Execute = 1
            BEGIN
                BEGIN TRY
                    EXEC sp_executesql @Cmd;
                    SET @Succeeded = 1;
                END TRY
                BEGIN CATCH
                    SET @ErrorMsg = ERROR_MESSAGE();

                    -- ONLINE failed: fall back to OFFLINE
                    IF @Action = 'REBUILD_ONLINE'
                    BEGIN
                        SET @Action = 'REBUILD_OFFLINE';
                        SET @Reason = @Reason + ' -> OFFLINE fallback';
                        SET @Cmd = 'ALTER INDEX ' + QUOTENAME(@Index) + ' ON ' + QUOTENAME(@DBName) + '.' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ' REBUILD' + @PartitionClause;
                        IF @MaxDOP IS NOT NULL
                            SET @Cmd = @Cmd + ' WITH (MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(5)) + ')';

                        BEGIN TRY
                            EXEC sp_executesql @Cmd;
                            SET @Succeeded = 1;
                            SET @ErrorMsg = NULL;
                        END TRY
                        BEGIN CATCH
                            SET @ErrorMsg = ERROR_MESSAGE();
                        END CATCH
                    END
                END CATCH
            END
            ELSE
                SET @Succeeded = 1;

            SET @OpEnd = SYSDATETIME();

            -------------------------------------------------------------------
            -- Log to history
            -------------------------------------------------------------------
            INSERT INTO optimize.IndexMaintenanceHistory
                (RunId, DatabaseName, SchemaName, TableName, IndexName, IndexType, PartitionNumber,
                 FragmentationPct, PageCount, SizeMB, Action, ActionReason, CommandExecuted,
                 StartTime, EndTime, Status, ErrorMessage)
            VALUES
                (@RunId, @DBName, @Schema, @Table, @Index, @IdxType, @Partition,
                 @Frag, @Pages, @Size, @Action, @Reason, @Cmd,
                 CASE WHEN @Execute = 1 THEN @OpStart ELSE NULL END,
                 CASE WHEN @Execute = 1 THEN @OpEnd ELSE NULL END,
                 CASE WHEN @Execute = 0 THEN 'DryRun' WHEN @Succeeded = 1 THEN 'Success' ELSE 'Failed' END,
                 @ErrorMsg);

            -- Update counters
            IF @Succeeded = 1 OR @Execute = 0
            BEGIN
                IF @Action = 'REORGANIZE'
                BEGIN
                    SET @TotalReorg = @TotalReorg + 1;
                    SET @TotalReorgMB = @TotalReorgMB + @Size;
                    SET @DBReorg = @DBReorg + 1;
                    SET @DBReorgMB = @DBReorgMB + @Size;
                END
                ELSE
                BEGIN
                    IF @Action = 'REBUILD_ONLINE'
                        SET @TotalRebuildOnline = @TotalRebuildOnline + 1;
                    ELSE
                        SET @TotalRebuildOffline = @TotalRebuildOffline + 1;
                    SET @TotalRebuildMB = @TotalRebuildMB + @Size;
                    SET @DBRebuild = @DBRebuild + 1;
                    SET @DBRebuildMB = @DBRebuildMB + @Size;
                END
            END
            ELSE
                SET @TotalFailed = @TotalFailed + 1;

            UPDATE #FragData SET Processed = 1 WHERE RowId = @RowId;

            FETCH NEXT FROM idx_cursor INTO @RowId, @Schema, @Table, @Index, @IdxId, @IdxType, @Partition, @Frag, @Pages, @Size;
        END

        CLOSE idx_cursor;
        DEALLOCATE idx_cursor;

        -----------------------------------------------------------------------
        -- Log time-limited indexes in current database
        -----------------------------------------------------------------------
        IF @TimeLimitReached = 1
        BEGIN
            DECLARE @SkippedCount INT;

            INSERT INTO optimize.IndexMaintenanceHistory
                (RunId, DatabaseName, SchemaName, TableName, IndexName, IndexType, PartitionNumber,
                 FragmentationPct, PageCount, SizeMB, Action, ActionReason, Status)
            SELECT
                @RunId, @DBName, SchemaName, TableName, IndexName, IndexType, PartitionNumber,
                FragmentationPct, PageCount, SizeMB,
                CASE WHEN FragmentationPct >= @RebuildThreshold THEN 'REBUILD' ELSE 'REORGANIZE' END,
                'Time limit reached',
                'TimeLimitReached'
            FROM #FragData
            WHERE Processed = 0;

            SET @SkippedCount = @@ROWCOUNT;
            SET @TotalTimeLimited = @TotalTimeLimited + @SkippedCount;

            SET @Msg = '  TIME LIMIT REACHED - ' + CAST(@SkippedCount AS VARCHAR(10)) + ' index(es) skipped in ' + @DBName;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        -- Per-database summary
        IF @DBReorg + @DBRebuild > 0
        BEGIN
            SET @Msg = '    Reorganized: ' + CAST(@DBReorg AS VARCHAR(10)) + ' (' + CAST(CAST(@DBReorgMB AS DECIMAL(10,1)) AS VARCHAR(20)) + ' MB)  Rebuilt: ' + CAST(@DBRebuild AS VARCHAR(10)) + ' (' + CAST(CAST(@DBRebuildMB AS DECIMAL(10,1)) AS VARCHAR(20)) + ' MB)';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        FETCH NEXT FROM db_cursor INTO @DBName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    ---------------------------------------------------------------------------
    -- Count remaining unscanned databases
    ---------------------------------------------------------------------------
    DECLARE @DBsSkipped INT = @DBCount - @DBsProcessed;

    IF @TimeLimitReached = 1 AND @DBsSkipped > 0
    BEGIN
        SET @Msg = '  TIME LIMIT - ' + CAST(@DBsSkipped AS VARCHAR(10)) + ' database(s) not scanned';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- Summary
    ---------------------------------------------------------------------------
    DECLARE @RunEndTime DATETIME2(3) = SYSDATETIME();
    DECLARE @RunDurationSec INT = DATEDIFF(SECOND, @RunStartTime, @RunEndTime);

    RAISERROR('', 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    RAISERROR('SUMMARY', 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    SET @Msg = '  Run ID:       ' + CAST(@RunId AS VARCHAR(10));
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = '  Duration:     ' + CAST(@RunDurationSec / 3600 AS VARCHAR(5)) + 'h ' + CAST((@RunDurationSec % 3600) / 60 AS VARCHAR(5)) + 'm ' + CAST(@RunDurationSec % 60 AS VARCHAR(5)) + 's';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = '  Databases:    ' + CAST(@DBsProcessed AS VARCHAR(10)) + ' scanned, ' + CAST(@DBsWithWork AS VARCHAR(10)) + ' with fragmentation';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    DECLARE @TotalProcessed INT = @TotalReorg + @TotalRebuildOnline + @TotalRebuildOffline;
    SET @Msg = '  Indexes:      ' + CAST(@TotalProcessed AS VARCHAR(10)) + ' processed';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @TotalReorg > 0
    BEGIN
        SET @Msg = '    Reorganized:      ' + CAST(@TotalReorg AS VARCHAR(10)) + ' (' + FORMAT(@TotalReorgMB, 'N1') + ' MB)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TotalRebuildOnline > 0
    BEGIN
        SET @Msg = '    Rebuilt (ONLINE):  ' + CAST(@TotalRebuildOnline AS VARCHAR(10)) + ' (' + FORMAT(@TotalRebuildMB, 'N1') + ' MB)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TotalRebuildOffline > 0
    BEGIN
        SET @Msg = '    Rebuilt (OFFLINE): ' + CAST(@TotalRebuildOffline AS VARCHAR(10));
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TotalFailed > 0
    BEGIN
        SET @Msg = '    Failed:           ' + CAST(@TotalFailed AS VARCHAR(10));
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TotalTimeLimited > 0
    BEGIN
        SET @Msg = '    Time Limited:     ' + CAST(@TotalTimeLimited AS VARCHAR(10));
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @TimeLimitReached = 1 AND @DBsSkipped > 0
    BEGIN
        SET @Msg = '    DBs Not Scanned:  ' + CAST(@DBsSkipped AS VARCHAR(10));
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    RAISERROR('============================================================', 10, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- Result set
    ---------------------------------------------------------------------------
    SELECT
        h.DatabaseName,
        h.SchemaName + '.' + h.TableName  AS [Object],
        h.IndexName,
        h.IndexType,
        h.FragmentationPct                AS [Frag%],
        h.PageCount                       AS Pages,
        h.SizeMB,
        h.Action,
        h.Status,
        h.DurationSeconds                 AS [Seconds],
        h.ActionReason,
        h.ErrorMessage
    FROM optimize.IndexMaintenanceHistory h
    WHERE h.RunId = @RunId
      AND h.SchemaName <> '-'
    ORDER BY h.DatabaseName, h.FragmentationPct DESC;

END
GO
