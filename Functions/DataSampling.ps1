# The main issue is in the Test-MustIncludeIds and Get-SampledData functions
# where $TableName is used directly in SQL queries without proper escaping/quoting.
# This can cause errors with special characters or spaces in table names.

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
        
        # Fix: Properly quote the table name
        $quotedTableName = """$TableName"""
        $cmd = New-Object System.Data.Odbc.OdbcCommand(
            "SELECT id FROM $quotedTableName WHERE id IN ($idList)", 
            $conn
        )
        
        $foundIds = New-Object System.Collections.Generic.HashSet[string]
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $foundIds.Add($reader.GetValue(0).ToString())
        }
        
        $missingIds = $ids | Where-Object { -not $foundIds.Contains($_) }
        
        if ($missingIds) {
            Write-Log "WARNING: The following must-include IDs were not found in ${TableName}: $($missingIds -join ', ')" -Level WARNING
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
        
        # Fix: Quote table names in all queries
        $quotedRootTable = """$RootTable"""
        
        # Calculate total records with quoted table name
        $cmd = New-Object System.Data.Odbc.OdbcCommand("SELECT COUNT(*) FROM $quotedRootTable", $conn)
        $totalRecords = [int]$cmd.ExecuteScalar()
        
        # ... Rest of the sampling logic with quoted table names ...
        $randomSampleQuery = @"
            SELECT FIRST $remainingNeeded id 
            FROM $quotedRootTable 
            WHERE 1=1 $excludeClause
            ORDER BY RANDOM
"@
        
        # When processing related tables, also quote their names
        while ($tablesToProcess.Count -gt 0) {
            $current = $tablesToProcess.Dequeue()
            $table = $current.Table
            $quotedTable = """$table"""
            $parentTable = $current.ParentTable
            $fkColumns = $current.ForeignKeys
            
            # Use quoted table name in queries
            $cmd = New-Object System.Data.Odbc.OdbcCommand(
                "SELECT DISTINCT id FROM $quotedTable WHERE $($whereClause -join ' OR ')",
                $conn
            )
            
            # ... Rest of the processing ...
        }
        
        return $sampledTables
    }
    finally {
        $conn.Close()
    }
}