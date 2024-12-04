# Name generation functions
function Get-WordLists {
    $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    try {
        $adjectives = Get-Content (Join-Path $scriptPath "..\adjectives.txt")
        $nouns = Get-Content (Join-Path $scriptPath "..\nouns.txt")
        
        if (-not $adjectives -or -not $nouns) {
            throw "Word lists are empty or could not be loaded"
        }
        
        return @{
            Adjectives = $adjectives
            Nouns = $nouns
        }
    }
    catch {
        Write-Log "Failed to load word lists: $_" -Level ERROR
        throw "Failed to initialize name generation"
    }
}

function Get-RandomName {
    param(
        [int]$Count = 1,
        [switch]$UniqueOnly
    )
    
    try {
        $words = Get-WordLists
        $names = @()
        $uniqueCheck = [System.Collections.Generic.HashSet[string]]::new()
        
        while ($names.Count -lt $Count) {
            $adj = $words.Adjectives | Get-Random
            $noun = $words.Nouns | Get-Random
            $name = "$adj-$noun"
            
            if ($UniqueOnly) {
                if ($uniqueCheck.Add($name)) {
                    $names += $name
                }
            }
            else {
                $names += $name
            }
        }
        
        if ($Count -eq 1) {
            return $names[0]
        }
        return $names
    }
    catch {
        Write-Log "Failed to generate random name: $_" -Level ERROR
        throw
    }
}

function Update-FieldWithRandomNames {
    param(
        [string]$DSN,
        [string]$DatabaseName,
        [string]$TableName,
        [string]$FieldName,
        [int]$BatchSize = 1000
    )
    
    Write-Log "Updating $TableName.$FieldName with random names..." -Level INFO
    
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN;DATABASE=$DatabaseName"
    $conn.Open()
    
    try {
        # Get total count
        $countCmd = New-Object System.Data.Odbc.OdbcCommand("SELECT COUNT(*) FROM $TableName", $conn)
        $totalRows = [int]$countCmd.ExecuteScalar()
        Write-Log "Total rows to update: $totalRows" -Level INFO
        
        # Process in batches
        for ($offset = 0; $offset -lt $totalRows; $offset += $BatchSize) {
            $names = Get-RandomName -Count $BatchSize -UniqueOnly
            
            # Get batch of rowids
            $rowidQuery = "SELECT FIRST $BatchSize SKIP $offset rowid FROM $TableName"
            $rowidCmd = New-Object System.Data.Odbc.OdbcCommand($rowidQuery, $conn)
            $rowids = @()
            $reader = $rowidCmd.ExecuteReader()
            while ($reader.Read()) {
                $rowids += $reader.GetValue(0)
            }
            $reader.Close()
            
            # Build update query
            $updateQuery = "UPDATE $TableName SET $FieldName = CASE rowid "
            for ($i = 0; $i -lt $rowids.Count; $i++) {
                $updateQuery += "WHEN $($rowids[$i]) THEN '$($names[$i])' "
            }
            $updateQuery += "END WHERE rowid IN (" + ($rowids -join ",") + ")"
            
            # Execute update
            $updateCmd = New-Object System.Data.Odbc.OdbcCommand($updateQuery, $conn)
            $rowsAffected = $updateCmd.ExecuteNonQuery()
            
            Write-Progress -Activity "Updating names" `
                          -Status "Processed $($offset + $rowsAffected) of $totalRows" `
                          -PercentComplete (($offset + $rowsAffected) / $totalRows * 100)
        }
        
        Write-Log "Successfully updated $totalRows rows with random names" -Level INFO
    }
    catch {
        Write-Log "Failed to update names in $TableName.$FieldName: $_" -Level ERROR
        throw
    }
    finally {
        $conn.Close()
    }
}