function Show-Tree {
    param(
        $Path = ".",
        [switch]$Files
    )
    Get-ChildItem -Path $Path -Recurse -Depth 10 ($Files ? $null : "-Directory") | ForEach-Object {
        $level = $_.FullName.Substring((Resolve-Path $Path).Path.Length).Split('\').Count - 1
        $indent = "│   " * ($level - 1)
        $prefix = "├── "
        if ($_.FullName -match "\\[^\\]*$") {
            $last = -not (Get-ChildItem $_.Parent.FullName -ErrorAction SilentlyContinue | Where-Object {
                $_.FullName -gt $_.FullName -and $_.FullName.StartsWith($_.Parent.FullName)
            })
            if ($last) { $prefix = "└── " }
        }
        $icon = if ($_.PSIsContainer) { "/" } else { "" }
        Write-Host "$indent$prefix$($_.Name)$icon"
    }
}

Show-Tree -Files