# Progress tracking class
class TransferProgress {
    [datetime]$StartTime
    [long]$TotalRows
    [long]$ProcessedRows
    [hashtable]$TableStats
    [string]$CurrentTable
    [int]$CompletedTables
    [int]$TotalTables
    [System.Collections.Generic.Dictionary[string,double]]$TransferRates
    
    TransferProgress([int]$totalTables) {
        $this.StartTime = Get-Date
        $this.TotalRows = 0
        $this.ProcessedRows = 0
        $this.TableStats = @{}
        $this.TotalTables = $totalTables
        $this.CompletedTables = 0
        $this.TransferRates = [System.Collections.Generic.Dictionary[string,double]]::new()
    }
    
    [void] UpdateProgress([string]$table, [long]$processedRows, [long]$totalRows) {
        $this.CurrentTable = $table
        if (-not $this.TableStats.ContainsKey($table)) {
            $this.TableStats[$table] = @{
                StartTime = Get-Date
                TotalRows = $totalRows
                ProcessedRows = 0
                LastUpdate = Get-Date
                LastProcessed = 0
            }
            $this.TotalRows += $totalRows
        }
        
        $stats = $this.TableStats[$table]
        $timeDiff = ((Get-Date) - $stats.LastUpdate).TotalSeconds
        
        if ($timeDiff -gt 0) {
            $rowDiff = $processedRows - $stats.LastProcessed
            $rate = $rowDiff / $timeDiff
            $this.TransferRates[$table] = $rate
        }
        
        $rowDiff = $processedRows - $stats.ProcessedRows
        $this.ProcessedRows += $rowDiff
        $stats.ProcessedRows = $processedRows
        $stats.LastUpdate = Get-Date
        $stats.LastProcessed = $processedRows
        
        if ($processedRows -eq $totalRows) {
            $this.CompletedTables++
        }
    }
    
    [string] GetEstimatedCompletion() {
        if ($this.ProcessedRows -eq 0) { return "Calculating..." }
        
        $elapsed = (Get-Date) - $this.StartTime
        $avgRate = $this.GetAverageTransferRate()
        
        if ($avgRate -eq 0) { return "Calculating..." }
        
        $remainingRows = $this.TotalRows - $this.ProcessedRows
        $remainingSeconds = $remainingRows / $avgRate
        
        return (Get-Date).AddSeconds($remainingSeconds).ToString("HH:mm:ss")
    }
    
    [double] GetAverageTransferRate() {
        if ($this.TransferRates.Count -eq 0) { return 0 }
        
        $total = 0.0
        foreach ($rate in $this.TransferRates.Values) {
            $total += $rate
        }
        return $total / $this.TransferRates.Count
    }
    
    [string] GetProgressReport() {
        $pct = [math]::Round(($this.ProcessedRows / $this.TotalRows) * 100, 1)
        $tablesPct = [math]::Round(($this.CompletedTables / $this.TotalTables) * 100, 1)
        $avgRate = [math]::Round($this.GetAverageTransferRate(), 1)
        
        return @"
Progress Report:
----------------
Current Table: $($this.CurrentTable)
Tables: $($this.CompletedTables)/$($this.TotalTables) ($tablesPct%)
Rows: $($this.ProcessedRows.ToString('N0'))/$($this.TotalRows.ToString('N0')) ($pct%)
Transfer Rate: $avgRate rows/sec
Elapsed: $([math]::Round(((Get-Date) - $this.StartTime).TotalMinutes, 1)) minutes
ETA: $($this.GetEstimatedCompletion())
"@
    }
}