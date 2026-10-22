/*
    SQL Server Optimization Suite
    Default Database: DBA_Utilities

    To install in a different database, find and replace all instances of
    "DBA_Utilities" with your database name before running this script.
*/
USE DBA_Utilities;
GO

CREATE OR ALTER PROCEDURE optimize.sp_AnalyzeQueryPlan
    @SQL          NVARCHAR(MAX)  = NULL,  -- query to analyze (executes it, grabs plan from cache)
    @PlanXML      XML            = NULL,  -- OR pass in a plan directly (from .sqlplan file or SSMS)
    @DatabaseName NVARCHAR(128)  = NULL,  -- database context for @SQL (NULL = current)
    @Debug        BIT = 0,
    -- Stale statistics thresholds (tiered: low sample + some mods, med sample + more mods, or high mods alone)
    @StatsLowModCount   INT           = 5000,    -- flag if mods > this AND sample < @StatsLowSamplePct
    @StatsLowSamplePct  DECIMAL(5,2)  = 10.0,
    @StatsMedModCount   INT           = 10000,   -- flag if mods > this AND sample < @StatsMedSamplePct
    @StatsMedSamplePct  DECIMAL(5,2)  = 50.0,
    @StatsHighModCount  INT           = 100000   -- flag if mods > this (regardless of sample)
AS
BEGIN
    SET NOCOUNT ON;

    -- =========================================================================
    -- PLAN CAPTURE: either from @PlanXML directly, or execute @SQL and grab from cache
    -- =========================================================================
    IF @PlanXML IS NULL AND @SQL IS NULL
    BEGIN
        SELECT 'ERROR' AS FindingType, 'Provide either @SQL or @PlanXML' AS Finding, NULL AS Detail, NULL AS Recommendation;
        RETURN;
    END

    IF @PlanXML IS NULL
    BEGIN
        DECLARE @ActualDB NVARCHAR(128) = ISNULL(@DatabaseName, DB_NAME());
        DECLARE @Marker NVARCHAR(100) = N'/*AnalyzeQP_' + REPLACE(CAST(NEWID() AS NVARCHAR(36)), N'-', N'') + N'*/';
        DECLARE @ExecSQL NVARCHAR(MAX) = N'USE ' + QUOTENAME(@ActualDB) + N'; ' + @Marker + N' ' + @SQL;

        BEGIN TRY
            EXEC sp_executesql @ExecSQL;
        END TRY
        BEGIN CATCH
            SELECT 'ERROR' AS FindingType, ERROR_MESSAGE() AS Finding, NULL AS Detail, NULL AS Recommendation;
            RETURN;
        END CATCH

        -- Grab the plan from cache using the unique marker
        SELECT TOP 1 @PlanXML = qp.query_plan
        FROM sys.dm_exec_cached_plans cp
        CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) qt
        CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
        WHERE qt.text LIKE N'%' + @Marker + N'%'
          AND qt.text NOT LIKE N'%dm_exec_cached_plans%';
    END

    IF @PlanXML IS NULL
    BEGIN
        SELECT 'ERROR' AS FindingType, 'No execution plan found in cache' AS Finding,
               'The query may have been too simple to cache, or the plan was evicted' AS Detail, NULL AS Recommendation;
        RETURN;
    END

    IF @Debug = 1
        SELECT @PlanXML AS CapturedPlan;

    -- Declare the showplan namespace
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT FindingType, Finding, Detail, Recommendation
    FROM (

    -- =========================================================================
    -- 1. MISSING INDEX RECOMMENDATIONS
    -- =========================================================================
    SELECT
        'MISSING_INDEX' AS FindingType,
        CAST(mix.value('@Impact', 'FLOAT') AS VARCHAR(20)) + '% impact' AS Finding,
        'Table: ' + mi.value('@Database', 'NVARCHAR(128)') + '.'
            + mi.value('@Schema', 'NVARCHAR(128)') + '.'
            + mi.value('@Table', 'NVARCHAR(128)') AS Detail,
        'CREATE NONCLUSTERED INDEX [IX_'
            + REPLACE(REPLACE(mi.value('@Table', 'NVARCHAR(128)'), '[', ''), ']', '')
            + '_missing] ON '
            + mi.value('@Schema', 'NVARCHAR(128)') + '.'
            + mi.value('@Table', 'NVARCHAR(128)')
            + ' ('
            + ISNULL(STUFF((
                SELECT ', ' + cg.value('@Name', 'NVARCHAR(128)')
                FROM mi.nodes('ColumnGroup[@Usage="EQUALITY"]/Column') AS eq(cg)
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), '')
            + CASE
                WHEN mi.exist('ColumnGroup[@Usage="EQUALITY"]') = 1
                 AND mi.exist('ColumnGroup[@Usage="INEQUALITY"]') = 1 THEN ', '
                ELSE '' END
            + ISNULL(STUFF((
                SELECT ', ' + cg.value('@Name', 'NVARCHAR(128)')
                FROM mi.nodes('ColumnGroup[@Usage="INEQUALITY"]/Column') AS iq(cg)
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), '')
            + ')'
            + CASE WHEN mi.exist('ColumnGroup[@Usage="INCLUDE"]') = 1
                THEN ' INCLUDE ('
                    + STUFF((
                        SELECT ', ' + cg.value('@Name', 'NVARCHAR(128)')
                        FROM mi.nodes('ColumnGroup[@Usage="INCLUDE"]/Column') AS ic(cg)
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
                    + ')'
                ELSE '' END
            + ';' AS Recommendation
    FROM @PlanXML.nodes('//MissingIndexes/MissingIndexGroup') AS mig(mix)
    CROSS APPLY mix.nodes('MissingIndex') AS m(mi)

    UNION ALL

    -- =========================================================================
    -- 2. STALE STATISTICS (high modification count or low sample rate)
    -- =========================================================================
    SELECT
        'STALE_STATISTICS' AS FindingType,
        s.value('@Statistics', 'NVARCHAR(128)') + ' on '
            + s.value('@Schema', 'NVARCHAR(128)') + '.'
            + s.value('@Table', 'NVARCHAR(128)') AS Finding,
        'Sample: ' + CAST(s.value('@SamplingPercent', 'DECIMAL(10,2)') AS VARCHAR(10)) + '%'
            + ' | Modifications: ' + CAST(s.value('@ModificationCount', 'BIGINT') AS VARCHAR(20))
            + ' | Last Updated: ' + ISNULL(CAST(s.value('@LastUpdate', 'DATETIME') AS VARCHAR(30)), '?') AS Detail,
        'UPDATE STATISTICS '
            + QUOTENAME(REPLACE(REPLACE(s.value('@Schema', 'NVARCHAR(128)'), '[', ''), ']', '')) + '.'
            + QUOTENAME(REPLACE(REPLACE(s.value('@Table', 'NVARCHAR(128)'), '[', ''), ']', '')) + ' '
            + QUOTENAME(REPLACE(REPLACE(s.value('@Statistics', 'NVARCHAR(128)'), '[', ''), ']', ''))
            + ' WITH FULLSCAN;' AS Recommendation
    FROM @PlanXML.nodes('//OptimizerStatsUsage/StatisticsInfo') AS si(s)
    WHERE (s.value('@ModificationCount', 'BIGINT') > @StatsLowModCount AND s.value('@SamplingPercent', 'DECIMAL(10,2)') < @StatsLowSamplePct)
       OR (s.value('@ModificationCount', 'BIGINT') > @StatsMedModCount AND s.value('@SamplingPercent', 'DECIMAL(10,2)') < @StatsMedSamplePct)
       OR s.value('@ModificationCount', 'BIGINT') > @StatsHighModCount

    UNION ALL

    -- =========================================================================
    -- 3. IMPLICIT CONVERSIONS
    -- =========================================================================
    SELECT DISTINCT
        'IMPLICIT_CONVERSION' AS FindingType,
        'CONVERT_IMPLICIT found in plan' AS Finding,
        sc.value('@ScalarString', 'NVARCHAR(MAX)') AS Detail,
        'Check column data types match parameter/join types to enable index seeks' AS Recommendation
    FROM @PlanXML.nodes('//ScalarOperator[contains(@ScalarString, "CONVERT_IMPLICIT")]') AS s(sc)

    UNION ALL

    -- =========================================================================
    -- 4. KEY LOOKUPS (detect via @PhysicalOp for estimated plans, @Lookup for actual)
    -- =========================================================================
    SELECT
        'KEY_LOOKUP' AS FindingType,
        'Key Lookup on ' + ISNULL(ro.value('(IndexScan/Object/@Table)[1]', 'NVARCHAR(128)'),
                                   ro.value('(*/Object/@Table)[1]', 'NVARCHAR(128)')) AS Finding,
        'Index: ' + ISNULL(ro.value('(IndexScan/Object/@Index)[1]', 'NVARCHAR(128)'),
                           ISNULL(ro.value('(*/Object/@Index)[1]', 'NVARCHAR(128)'), '?'))
            + ' | Est. Rows: ' + CAST(ro.value('@EstimateRows', 'FLOAT') AS VARCHAR(20))
            + ' | Est. Executions: ' + CAST(ISNULL(ro.value('@EstimatedExecutions', 'FLOAT'), 1) AS VARCHAR(20)) AS Detail,
        'Add columns to the nonclustered index feeding this lookup as INCLUDEs to eliminate it' AS Recommendation
    FROM @PlanXML.nodes('//RelOp[@PhysicalOp="Key Lookup"]') AS r(ro)

    UNION ALL

    -- =========================================================================
    -- 5. LARGE CARDINALITY MISESTIMATES (actual vs estimated > 100x)
    -- =========================================================================
    SELECT
        'CARDINALITY_ISSUE' AS FindingType,
        ro.value('@PhysicalOp', 'NVARCHAR(128)') + ' on '
            + ISNULL(ro.value('(.//Object/@Table)[1]', 'NVARCHAR(128)'), '?') AS Finding,
        'Estimated: ' + CAST(ro.value('@EstimateRows', 'FLOAT') AS VARCHAR(30))
            + ' | Actual: ' + CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 0) AS VARCHAR(30))
            + ' | Ratio: '
            + CAST(CASE
                WHEN ro.value('@EstimateRows', 'FLOAT') > 0
                THEN CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 0) AS FLOAT)
                     / ro.value('@EstimateRows', 'FLOAT')
                ELSE 0 END AS VARCHAR(30))
            + 'x' AS Detail,
        'Statistics on this table are likely stale — check STALE_STATISTICS findings above' AS Recommendation
    FROM @PlanXML.nodes('//RelOp') AS r(ro)
    WHERE ro.value('@EstimateRows', 'FLOAT') > 0
      AND ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 0) > 0
      AND (
          CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 0) AS FLOAT)
              / ro.value('@EstimateRows', 'FLOAT') > 100
          OR ro.value('@EstimateRows', 'FLOAT')
              / CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 1) AS FLOAT) > 100
      )

    UNION ALL

    -- =========================================================================
    -- 6. MANY-TO-MANY MERGE JOINS (can explode row counts)
    -- =========================================================================
    SELECT
        'MANY_TO_MANY_MERGE' AS FindingType,
        'Many-to-Many Merge Join' AS Finding,
        'Est. Rows: ' + CAST(ro.value('@EstimateRows', 'FLOAT') AS VARCHAR(30))
            + ' | Actual Rows: ' + CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 0) AS VARCHAR(30))
            + ' | Rows Read: ' + CAST(ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRowsRead)[1]', 'BIGINT'), 0) AS VARCHAR(30)) AS Detail,
        'Many-to-many merge joins can read exponentially more rows than output. Check statistics or consider hash join hint.' AS Recommendation
    FROM @PlanXML.nodes('//RelOp[@PhysicalOp="Merge Join"]') AS r(ro)
    CROSS APPLY ro.nodes('Merge') AS m(mj)
    WHERE mj.value('@ManyToMany', 'BIT') = 1
      AND ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRowsRead)[1]', 'BIGINT'), 0)
          > ISNULL(ro.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)[1]', 'BIGINT'), 1) * 100

    ) AS results
    ORDER BY
        CASE FindingType
            WHEN 'MANY_TO_MANY_MERGE' THEN 1
            WHEN 'STALE_STATISTICS' THEN 2
            WHEN 'MISSING_INDEX' THEN 3
            WHEN 'KEY_LOOKUP' THEN 4
            WHEN 'CARDINALITY_ISSUE' THEN 5
            WHEN 'IMPLICIT_CONVERSION' THEN 6
            ELSE 7
        END;
END
GO
