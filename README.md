# Indexing

SQL Server index management suite. Two pillars: **optimization** (finding and fixing index problems) and **maintenance** (keeping indexes and statistics healthy).

All objects live in `DBA_Utilities` — optimization tools in the `indexing` schema, maintenance tools in `indexing` and `dbo` schemas.

## Structure

```
indexing/
├── optimization/
│   ├── build/                              # Build script for combined install
│   │   └── build_install_script.py
│   ├── install/                            # Auto-generated install script
│   │   └── INSTALL_IndexOptimizationSuite.sql
│   ├── documentation/                      # CLAUDE.md, README.md, wiki/
│   ├── suite/                              # Orchestrator + summary + shared utility
│   │   ├── suite.sql
│   │   ├── suite.md
│   │   └── run-scripts.sql
│   └── tools/                              # One .sql + one .md per tool
│       ├── duplicate-index/
│       ├── key-lookup-elimination/
│       ├── unused-index-detection/
│       ├── optimize-index/
│       ├── expensive-query-plan-analysis/
│       ├── column-access-pattern-analysis/
│       ├── query-plan-analysis/
│       └── help-index-usage/
│
├── maintenance/
│   ├── index/                              # Index defragmentation (REORG/REBUILD)
│   │   ├── index-maintenance.sql
│   │   └── index-maintenance.md
│   ├── statistics/                         # Stale statistics detection and update
│   │   ├── statistics-maintenance.sql
│   │   └── statistics-maintenance.md
│   └── wiki/
│
└── summaries/                              # Historical HTML summary reports
```

## Quick Start

```sql
-- Run the full optimization suite
EXEC indexing.sp_IndexOptimizationSuite @DatabaseName = 'mc_%', @RunnableUnder = '1,5e';

-- Combined output with linked server support
EXEC indexing.sp_IndexOptimizationSuite @DatabaseName = 'mc_%', @RunnableUnder = '1,5e',
    @CombinedOutput = 1, @LinkedServer = 1;

-- Index maintenance (dry run, then execute)
EXEC indexing.sp_IndexMaintenance;
EXEC indexing.sp_IndexMaintenance @Execute = 1;

-- Statistics maintenance
EXEC dbo.sp_StatisticsMaintenance @Run = 1, @StatisticsSample = 100;

-- Diagnose a specific slow query
EXEC indexing.sp_AnalyzeQueryPlan @SQL = 'SELECT ...', @DatabaseName = 'mc_myclient_1234';

-- Fleet-wide summary of all optimization activity
EXEC indexing.sp_IndexingSuiteSummary @Days = 7, @Detail = 1;
```

See `optimization/suite/run-scripts.sql` for the full parameter reference.
