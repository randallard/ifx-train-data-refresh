# Data sampling functions
function Get-TableRelationships {
    param (
        [string]$DSN,
        [string]$DatabaseName
    )
    
    $relationships = @{}
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN;DATABASE=$DatabaseName"
    $conn.Open()
    
    try {
        $cmd = New-Object System.Data.Odbc.OdbcCommand(@"
            SELECT
                c.constrname as constraint_name,
                t1.tabname as parent_table,
                t2.tabname as child_table,
                (
                    SELECT STRING_AGG(fname, ',')
                    FROM sysconstraints sc2
                    JOIN sysindexes si ON sc2.idxname = si.idxname
                    JOIN syscolumns col ON si.part1 = col.colno
                    WHERE sc2.constrid = c.constrid
                ) as foreign_key_columns
            FROM
                sysconstraints c
                JOIN systables t1 ON c.primary = t1.tabid
                JOIN systables t2 ON c.foreign = t2.tabid
            WHERE
                c.constrtype = 'R'
"@, $conn)
        
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $childTable = $reader.GetString(2)
            $parentTable = $reader.GetString(1)
            $fkColumns = $reader.GetString(3)
            
            if (-not $relationships.ContainsKey($parentTable)) {
                $relationships[$parentTable] = @{}
            }
            
            $relationships[$parentTable][$childTable] = $fkColumns.Split(',')
        }
    }
    finally {
        $conn.Close()
    }
    
    return $relationships
}

function Test-MustIncludeIds {
    param(
        [string]$DSN,
        [string]$DatabaseName,
        [string]$TableName,
        [string]$IdList
    )
    
    if ([string]::IsNullOrWhiteSpace($IdList)) { return $true }
    
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN;DATABASE=$DatabaseName"
    $conn.Open()
    
    try {
        $ids = $IdList.Split(',') | ForEach-Object { $_.Trim() }
        $idList = $ids -join ','
        
        $cmd = New-Object System.Data.Odbc.OdbcCommand(
            "SELECT id FROM $TableName WHERE id IN ($idList)", 
            $conn
        )
        
        $foundIds = New-Object System.Collections.Generic.HashSet[string]
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $foundIds.Add($reader.GetValue(0).ToString())
        }
        
        $missingIds = $ids | Where-Object { -not $foundIds.Contains($_) }
        
        if ($missingIds) {
            Write-Log "WARNING: The following must-include IDs were not found in $TableName: $($missingIds -join ', ')" -Level WARNING
            return $false
        }
        
        return $true
    }
    finally {
        $conn.Close()
    }
}

function Get-SampledData {
    param (
        [string]$DSN,
        [string]$DatabaseName,
        [string]$RootTable,
        [int]$SamplePercentage,
        [hashtable]$Relationships,
        [string]$MustIncludeIds
    )
    
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN;DATABASE=$DatabaseName"
    $conn.Open()
    
    try {
        Write-Log "Starting sampling for $RootTable" -Level INFO
        
        # Validate must-include IDs
        if ($MustIncludeIds) {
            Write-Log "Validating must-include IDs for $RootTable" -Level INFO
            if (-not (Test-MustIncludeIds -DSN $DSN -DatabaseName $DatabaseName -TableName $RootTable -IdList $MustIncludeIds)) {
                throw "Some must-include IDs were not found in the table"
            }
        }
        
        # First, get the must-include IDs
        $rootIds = New-Object System.Collections.Generic.HashSet[string]
        if ($MustIncludeIds) {
            $mustIncludeList = $MustIncludeIds.Split(',') | ForEach-Object { $_.Trim() }
            $mustIncludeList | ForEach-Object { $rootIds.Add($_) }
            Write-Log "Added $($mustIncludeList.Count) must-include IDs for $RootTable" -Level INFO
        }
        
        # Calculate how many additional random records we need
        $cmd = New-Object System.Data.Odbc.OdbcCommand("SELECT COUNT(*) FROM $RootTable", $conn)
        $totalRecords = [int]$cmd.ExecuteScalar()
        $targetSampleSize = [math]::Ceiling($totalRecords * ($SamplePercentage / 100))
        $remainingNeeded = $targetSampleSize - $rootIds.Count
        
        if ($remainingNeeded -gt 0) {
            # Get additional random records, excluding must-include IDs
            $excludeClause = if ($rootIds.Count -gt 0) {
                "AND id NOT IN (" + ($rootIds -join ',') + ")"
            } else { "" }
            
            $randomSampleQuery = @"
                SELECT FIRST $remainingNeeded id 
                FROM $RootTable 
                WHERE 1=1 $excludeClause
                ORDER BY RANDOM
"@
            
            $cmd = New-Object System.Data.Odbc.OdbcCommand($randomSampleQuery, $conn)
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $rootIds.Add($reader.GetValue(0).ToString())
            }
            $reader.Close()
        }
        
        Write-Log "Sampled total of $($rootIds.Count) records from $RootTable" -Level INFO
        
        # Now get related records
        $sampledTables = @{
            $RootTable = $rootIds
        }
        
        $tablesToProcess = New-Object System.Collections.Queue
        if ($Relationships.ContainsKey($RootTable)) {
            $Relationships[$RootTable].Keys | ForEach-Object { 
                $tablesToProcess.Enqueue(@{
                    Table = $_
                    ParentTable = $RootTable
                    ForeignKeys = $Relationships[$RootTable][$_]
                })
            }
        }
        
        while ($tablesToProcess.Count -gt 0) {
            $current = $tablesToProcess.Dequeue()
            $table = $current.Table
            $parentTable = $current.ParentTable
            $fkColumns = $current.ForeignKeys
            
            Write-Log "Processing related records for $table" -Level INFO
            
            # Get related records
            $whereClause = $fkColumns | ForEach-Object { 
                "$_ IN (" + ($sampledTables[$parentTable] -join ',') + ")"
            }
            
            $cmd = New-Object System.Data.Odbc.OdbcCommand(
                "SELECT DISTINCT id FROM $table WHERE $($whereClause -join ' OR ')",
                $conn
            )
            
            $relatedIds = New-Object System.Collections.Generic.HashSet[string]
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $relatedIds.Add($reader.GetValue(0).ToString())
            }
            $reader.Close()
            
            $sampledTables[$table] = $relatedIds
            Write-Log "Found $($relatedIds.Count) related records in $table" -Level INFO
            
            # Add child tables to queue
            if ($Relationships.ContainsKey($table)) {
                $Relationships[$table].Keys | ForEach-Object { 
                    $tablesToProcess.Enqueue(@{
                        Table = $_
                        ParentTable = $table
                        ForeignKeys = $Relationships[$table][$_]
                    })
                }
            }
        }
        
        return $sampledTables
    }
    finally {
        $conn.Close()
    }
}