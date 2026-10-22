# SQL Server Optimization Suite

A comprehensive SQL Server index optimization and maintenance toolkit. Eight tools that find what's missing, remove what's redundant, diagnose what's slow, and keep your indexes and statistics healthy — plus an orchestrator that runs them all with one call.

One script, one schema, every server.

## What's Included

### Optimization Tools
| Tool | What It Does |
|------|-------------|
| **Duplicate Index Detection** | Finds duplicate, redundant, and combinable indexes. Generates DROP and COMBINE scripts with size estimation. |
| **Key Lookup Elimination** | Scans the plan cache for key lookups and recommends INCLUDE columns to eliminate double I/O. |
| **Unused Index Detection** | Identifies indexes with zero reads and active write overhead. DISABLE (reversible) or DROP with confidence levels. |
| **Missing Index Recommendations** | Multi-stage consolidation pipeline that reduces hundreds of raw DMV suggestions into actionable, non-overlapping recommendations. |
| **Expensive Query Analysis** | Finds the most expensive queries in the plan cache — table scans, missing index hints, and regressed queries. |
| **Column Access Patterns** | Discovers which columns are most frequently filtered, joined, and sorted on for composite index opportunities. |
| **Query Plan Analysis** | One-off diagnostic: pass a slow query, get back stale statistics, missing indexes, implicit conversions, and cardinality issues with ready-to-run fix scripts. |
| **sp_helpindexUsage** | Enhanced sp_helpindex with usage stats, column-level detail, and index sizes in one result set. |

### Maintenance Tools
| Tool | What It Does |
|------|-------------|
| **Index Maintenance** | Automated defragmentation with edition-aware REORG/REBUILD. ONLINE rebuilds on Enterprise with automatic OFFLINE fallback. Time limits, history logging, and smart thresholds. |
| **Statistics Maintenance** | Stale statistics detection and targeted updates based on modification rates and table size. Replaces blanket UPDATE STATISTICS with surgical precision. |

### Orchestration
| Component | What It Does |
|-----------|-------------|
| **sp_IndexOptimizationSuite** | Runs all optimization tools in the correct order with one call. Combined output mode organizes findings by database and table. Linked server support for running from a central ops server. |
| **sp_IndexingSuiteSummary** | Fleet-wide reporting across all tools with optional row-level detail. |

## Download

| Script | Description |
|--------|-------------|
| [INSTALL_IndexOptimizationSuite.sql](https://github.com/mja1175/SQL-Server-Optimization/tree/main/tools/INSTALL_IndexOptimizationSuite.sql) | Core suite — all 6 optimization tools + orchestrator + summary |
| [index-maintenance.sql](https://github.com/mja1175/SQL-Server-Optimization/tree/main/tools/index-maintenance.sql) | Index defragmentation (REORG/REBUILD) |
| [statistics-maintenance.sql](https://github.com/mja1175/SQL-Server-Optimization/tree/main/tools/statistics-maintenance.sql) | Stale statistics detection and update |
| [query-plan-analysis.sql](https://github.com/mja1175/SQL-Server-Optimization/tree/main/tools/query-plan-analysis.sql) | One-off query plan diagnostics |
| [help-index-usage.sql](https://github.com/mja1175/SQL-Server-Optimization/tree/main/tools/help-index-usage.sql) | Enhanced sp_helpindex with usage stats |

Or clone the full repo: `git clone https://github.com/mja1175/SQL-Server-Optimization.git`

## Installation

**Prerequisites:** SQL Server 2016+, a `DBA_Utilities` database on each server.

### Core Suite (required)
```sql
-- Installs all 6 optimization tools + orchestrator + summary
USE DBA_Utilities;
GO
-- Execute INSTALL_IndexOptimizationSuite.sql
```

### Maintenance Tools (recommended)
```sql
-- Index defragmentation (REORG/REBUILD with edition-aware defaults)
USE DBA_Utilities;
GO
-- Execute tools/index-maintenance.sql

-- Statistics maintenance (stale stats detection and targeted updates)
USE DBA_Utilities;
GO
-- Execute tools/statistics-maintenance.sql
```

### Standalone Diagnostics (optional)
```sql
-- Query plan analysis (one-off slow query diagnostics)
USE DBA_Utilities;
GO
-- Execute tools/query-plan-analysis.sql

-- sp_helpindexUsage (installs in master, not DBA_Utilities)
USE master;
GO
-- Execute tools/help-index-usage.sql
```

All scripts are safe to re-run. Tables use `IF NOT EXISTS` (data preserved). Procedures use `CREATE OR ALTER` (always updated).

## Quick Start

```sql
-- Run the full suite
EXEC optimize.sp_IndexOptimizationSuite
    @Databases = 'USER_DATABASES'     -- Ola-style: USER_DATABASES, ALL_DATABASES, %pattern%, -exclusions
    ,@RunnableUnder = '1,5e'          -- NULL = all uncommented. '1,5e' = 1GB Standard / 5GB Enterprise.
    ,@CombinedOutput = 1;             -- One script organized by database -> table -> tool.

-- Fleet-wide summary
EXEC optimize.sp_IndexingSuiteSummary @Days = 7;

-- Diagnose a specific slow query
EXEC optimize.sp_AnalyzeQueryPlan
    @SQL = 'SELECT ... FROM ... WHERE ...',
    @DatabaseName = 'MyDatabase';

-- Index maintenance (dry run, then execute)
EXEC optimize.sp_IndexMaintenance @Execute = 0;  -- Preview
EXEC optimize.sp_IndexMaintenance @Execute = 1;  -- Execute

-- Statistics maintenance
EXEC optimize.sp_StatisticsMaintenance @Run = 1, @StatisticsSample = 100;
```

## Key Features

### @Databases — Ola Hallengren-Style Database Selection
Flexible database targeting with keywords, wildcards, and exclusions:
- `USER_DATABASES` — all user databases (default)
- `SYSTEM_DATABASES` — master, msdb, model
- `ALL_DATABASES` — everything
- `AVAILABILITY_GROUP_DATABASES` — databases in AGs
- `%pattern%` — wildcard matching
- `-DbName` or `-%pattern%` — exclusions
- Combine freely: `USER_DATABASES, -TestDb, -%_dev`

### Edition-Aware
Automatically detects Enterprise vs Standard edition. Enterprise gets `WITH (ONLINE = ON)` for index operations and more aggressive rebuild thresholds (since online rebuilds don't block queries).

### @RunnableUnder — Smart Threshold Commenting
Control which index operations are auto-executable vs. commented out for manual review:
- `NULL` — everything uncommented (all executable)
- `'2'` — indexes estimated >= 2 GB are commented out
- `'1,5e'` — 1 GB threshold for Standard, 5 GB for Enterprise (separate thresholds because Enterprise can rebuild online)

### Linked Server Support
Run the suite from a central ops server. Pass `@LinkedServer = 1` and the output script wraps each statement in `EXEC(...) AT [server]` syntax — ready to execute from your ops window without connecting to each server individually.

### Size Estimation
Index size estimates use actual data sampling (`AVG(DATALENGTH())` on 10,000 rows) instead of `max_length` guesses. Estimates are always >= current index size because adding columns can never shrink an index.

### ResolvedDate Tracking
Every recommendation includes an `UPDATE ... SET ResolvedDate = GETDATE()` statement. When you execute the fix, the recommendation is marked resolved. Re-running the suite only shows unresolved findings — no duplicates, clear progress tracking.

## Documentation

Full documentation is available at [optimizesqlserver.com](https://optimizesqlserver.com).

## License

MIT License — see [LICENSE](LICENSE).

© 2026 Mike Armstrong
