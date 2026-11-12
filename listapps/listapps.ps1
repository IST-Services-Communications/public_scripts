# Developed by Fernando Fontana under the MIT License, 2022.
# This means that you can use this script for free, but you can't sell it.
# Also if you modify it, you must share the modifications under the same license.
#
# In other words: You can do whatever you want as long as you include the original copyright
# and license notice in any copy of the software/source.
#
# This script creates the listapps function, that can be used to list all installed programs on the computer.
# Currently it can get the list from the registry, scoop, winget, chocolatey, pip, pipx, npm, yarn and cargo.
#
# It works as wrapper for other commands, so it is not necessary to install it.
# Just copy the file into your PowerShell profile folder and add the following line to your profile:
# Invoke-Expression (Get-Content -Path .\Documents\PowerShell\listapps.ps1 -Raw)
#
# To see the instructions on how to use this script, run:
# listapps --help
#
# It can be powerful when combined with tools like:
# - fzf        Powerful Fuzzy Finder to filter the list
# - ripgrep    Powerful RegEx search on the list
# - more       Show the list in a pager
# ...And other commands like peco, grep, findstr, etc.
#
# Examples:
# listapps | fzf
# listapps | rg -i "python"
# listapps --choco | fzf
#
# Another possibility is to save the list to a file and use it with other commands:
# listapps --choco > choco_apps.txt
# listapps --yarn > yarn_packages.txt
#
# The cited above functions may be implemented on this script in the future.
# Or may I develop a whole new cli program with a better interface and more features.
# But for now, this is a simple script that works well enough for me.
# =========================================================================================================================================================

function ConvertTo-InstallSourceKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return ($Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function Add-InstallSourceEntry {
    param(
        [hashtable]$SourceIndex,
        [System.Collections.Generic.List[object]]$Programs,
        [string]$Name,
        [string]$Source,
        [string]$Version
    )

    $key = ConvertTo-InstallSourceKey $Name
    if (-not $key) {
        return
    }

    if (-not $SourceIndex.ContainsKey($key)) {
        $SourceIndex[$key] = @()
    }

    $SourceIndex[$key] = @($SourceIndex[$key] + $Source | Sort-Object -Unique)
    $Programs.Add([PSCustomObject]@{
        DisplayName = $Name
        DisplayVersion = if ($Version) { $Version } else { 'unknown' }
        Publisher = 'unknown'
        InstallSource = $Source
    })
}

function Write-SourceCheckWarning {
    param(
        [string]$Manager,
        [int]$ExitCode,
        [object[]]$Output
    )

    $detail = ($Output | Select-Object -First 1 | ForEach-Object { "$_" }) -join ' '
    if ($detail) {
        Write-Warning "$Manager source check failed with exit code $ExitCode`: $detail"
    }
    else {
        Write-Warning "$Manager source check failed with exit code $ExitCode."
    }
}

function Test-PackageManagerAvailable {
    param([string]$Name)

    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Assert-PackageManagerAvailable {
    param([string]$Name)

    if (-not (Test-PackageManagerAvailable -Name $Name)) {
        throw "Package manager '$Name' is not installed or not available on PATH. Run 'listapps check' to see available managers."
    }
}

function Get-PackageManagerStatus {
    foreach ($name in @('scoop', 'winget', 'choco', 'pip', 'pipx', 'npm', 'yarn', 'cargo')) {
        [PSCustomObject]@{
            PackageManager = $name
            Available = Test-PackageManagerAvailable -Name $name
        }
    }
}

function show-installed-programs-check {
    Write-Output 'Package manager availability:'
    Get-PackageManagerStatus | Format-Table -AutoSize
}

function Get-WingetPrograms {
    param([string[]]$Output)

    $headerIndex = -1
    for ($i = 0; $i -lt $Output.Count; $i++) {
        if ($Output[$i] -match '^\s*Name\s+Id\s+Version\b') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0) {
        if ($Output.Count -gt 0 -and ($Output -join [Environment]::NewLine) -notmatch 'No installed package found') {
            Write-Warning 'winget list output did not contain the expected table header.'
        }
        return
    }

    $header = $Output[$headerIndex]
    $columns = [regex]::Matches($header, '\S+')
    if ($columns.Count -lt 3) {
        Write-Warning 'winget list output did not contain the expected columns.'
        return
    }

    $idStart = $columns[1].Index
    $versionStart = $columns[2].Index
    $versionEnd = if ($columns.Count -gt 3) { $columns[3].Index } else { [int]::MaxValue }
    for ($i = $headerIndex + 1; $i -lt $Output.Count; $i++) {
        $line = $Output[$i]
        if ($line -match '^\s*-{5,}\s*$' -or $line.Length -le $idStart) {
            continue
        }

        $idLength = [Math]::Min($versionStart, $line.Length) - $idStart
        if ($idLength -le 0) {
            continue
        }

        $packageId = $line.Substring($idStart, $idLength).Trim()
        if ($packageId -notmatch '^\S+$') {
            continue
        }

        $name = $line.Substring(0, $idStart).Trim()
        if ($name) {
            $versionLength = [Math]::Min($versionEnd, $line.Length) - $versionStart
            $version = if ($versionLength -gt 0) { $line.Substring($versionStart, $versionLength).Trim() } else { 'unknown' }
            [PSCustomObject]@{
                Name = $name
                Version = if ($version) { $version } else { 'unknown' }
            }
        }
    }
}

function Get-InstallSourceIndex {
    $sourceIndex = @{}
    $programs = [System.Collections.Generic.List[object]]::new()

    if (Test-PackageManagerAvailable -Name 'winget') {
        $output = @(& winget list --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-SourceCheckWarning -Manager 'winget' -ExitCode $exitCode -Output $output
        }
        else {
            foreach ($package in Get-WingetPrograms -Output $output) {
                Add-InstallSourceEntry -SourceIndex $sourceIndex -Programs $programs -Name $package.Name -Source 'winget' -Version $package.Version
            }
        }
    }

    if (Test-PackageManagerAvailable -Name 'scoop') {
        $output = & scoop export 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-SourceCheckWarning -Manager 'scoop' -ExitCode $exitCode -Output $output
        }
        else {
            $export = ($output -join [Environment]::NewLine) | ConvertFrom-Json
            foreach ($package in $export.apps) {
                Add-InstallSourceEntry -SourceIndex $sourceIndex -Programs $programs -Name $package.Name -Source 'scoop' -Version $package.Version
            }
        }
    }

    if (Test-PackageManagerAvailable -Name 'choco') {
        $output = & choco list --local-only --limit-output 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-SourceCheckWarning -Manager 'choco' -ExitCode $exitCode -Output $output
        }
        else {
            foreach ($line in $output) {
                if ("$line" -match '^([^|]+)\|([^|]+)') {
                    Add-InstallSourceEntry -SourceIndex $sourceIndex -Programs $programs -Name $Matches[1] -Source 'choco' -Version $Matches[2]
                }
            }
        }
    }

    return [PSCustomObject]@{
        Index = $sourceIndex
        Programs = $programs.ToArray()
    }
}

function Resolve-InstallSource {
    param(
        [string]$Name,
        [hashtable]$SourceIndex
    )

    $key = ConvertTo-InstallSourceKey $Name
    if (-not $key -or -not $SourceIndex.ContainsKey($key)) {
        return 'unknown'
    }

    $sources = @($SourceIndex[$key] | Sort-Object -Unique)
    if ($sources.Count -eq 1) {
        return $sources[0]
    }

    return 'unknown'
}

# List all programs installed on the computer using the registry
function show-installed-programs-hklm {
    $sourceData = Get-InstallSourceIndex
    $programs = [System.Collections.Generic.List[object]]::new()
    $representedNames = @{}

    foreach ($entry in (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*)) {
        $program = [PSCustomObject]@{
            DisplayName = $entry.DisplayName
            DisplayVersion = $entry.DisplayVersion
            Publisher = $entry.Publisher
            InstallSource = Resolve-InstallSource -Name $entry.DisplayName -SourceIndex $sourceData.Index
        }
        $programs.Add($program)

        $key = ConvertTo-InstallSourceKey $entry.DisplayName
        if ($key) {
            $representedNames[$key] = $true
        }
    }

    foreach ($managerProgram in $sourceData.Programs) {
        $key = ConvertTo-InstallSourceKey $managerProgram.DisplayName
        if (-not $key -or $representedNames.ContainsKey($key)) {
            continue
        }

        $managerProgram.InstallSource = Resolve-InstallSource -Name $managerProgram.DisplayName -SourceIndex $sourceData.Index
        $programs.Add($managerProgram)
        $representedNames[$key] = $true
    }

    return $programs | Sort-Object DisplayName
}

function Format-InstalledProgramList {
    param([object[]]$Programs)

    $Programs |
        Sort-Object DisplayName |
        Format-Table -Wrap -Property `
            @{ Label = 'DisplayName'; Expression = { $_.DisplayName }; Width = 48 },
            @{ Label = 'DisplayVersion'; Expression = { $_.DisplayVersion }; Width = 16 },
            @{ Label = 'Publisher'; Expression = { $_.Publisher }; Width = 25 },
            @{ Label = 'InstallSource'; Expression = { $_.InstallSource }; Width = 13 }
}

# List all programs installed with scoop
function show-installed-programs-scoop {
    Assert-PackageManagerAvailable -Name 'scoop'
    scoop list
}
# List all programs installed with winget
function show-installed-programs-winget {
    Assert-PackageManagerAvailable -Name 'winget'
    winget list
}
# List all programs installed with choco
function show-installed-programs-choco {
    Assert-PackageManagerAvailable -Name 'choco'
    choco list --local-only
}

# The following funciton list the apps instelled on the computer
function show-installed-programs {
    param(
        [Parameter(Position = 0)]
        [string]$Manager = 'default',
        [string]$ShowSources = 'true',
        [switch]$Csv,
        [string]$CsvPath,
        [switch]$Force
    )

    if ($Manager -eq '--help' -or $Manager -eq '-h') {
        Write-Host "List all programs and applications installed on the computer."
        Write-Host ""
        Write-Host "Usage: listapps [MANAGER] [-ShowSources true|false] [-Csv [PATH]] [-CsvPath PATH] [-Force]"
        Write-Host ""
        Write-Host "OPTIONS AVAILABLE: "
        Write-Host ""
        Write-Host "        default          List all programs installed on the computer"
        Write-Host "        computer         List all programs installed on the computer        (alias for default)"
        Write-Host "        choco            List all programs installed with choco"
        Write-Host "        chocolatey       List all programs installed with choco             (alias for choco)"
        Write-Host "        scoop            List all programs installed with scoop"
        Write-Host "        winget           List all programs installed with winget"
        Write-Host "        pip              List all programs installed with pip"
        Write-Host "        pipx             List all programs under pipx virtual environments"
        Write-Host "        npm              List all packages installed with npm"
        Write-Host "        yarn             List all packages installed with yarn"
        Write-Host "        cargo            List all programs installed with cargo"
        Write-Host ""
        Write-Host "        check            Show availability of each package manager"
        Write-Host ""
        Write-Host "The default listing includes an InstallSource column; unknown means no unique manager match was found."
        Write-Host "Use -Csv to save the default listing as listapps.csv, or -Csv PATH / -CsvPath PATH to choose a path."
        Write-Host "Use -Force to overwrite an existing CSV file."
        Write-Host ""
        Write-Host " -h     --help           Show this help message"
        return
    }

    $exportCsv = $Csv.IsPresent -or $PSBoundParameters.ContainsKey('CsvPath')
    if (-not $exportCsv -and ($Manager -eq 'check' -or $Manager -eq 'sources')) {
        show-installed-programs-check
        return
    }

    $isDefaultManager = $exportCsv -or $Manager -eq 'default' -or $Manager -eq 'computer'
    if ($exportCsv) {
        $showSourceReport = $false
    }
    elseif ($ShowSources -ieq 'true') {
        $showSourceReport = $true
    }
    elseif ($ShowSources -ieq 'false') {
        $showSourceReport = $false
    }
    else {
        throw "Invalid value for -ShowSources: '$ShowSources'. Use true or false."
    }

    $resolvedCsvPath = $null
    if ($exportCsv) {
        $knownManagers = @('default', 'computer', 'check', 'sources', 'scoop', 'winget', 'choco', 'chocolatey', 'pip', 'pipx', 'npm', 'yarn', 'cargo', '-cargo')
        if ($CsvPath) {
            $resolvedCsvPath = $CsvPath
        }
        elseif ($Csv.IsPresent -and $knownManagers -notcontains $Manager.ToLowerInvariant()) {
            $resolvedCsvPath = $Manager
        }
        else {
            $resolvedCsvPath = Join-Path (Get-Location) 'listapps.csv'
        }

        if ((Test-Path -LiteralPath $resolvedCsvPath) -and -not $Force) {
            throw "CSV file '$resolvedCsvPath' already exists. Use -Force to overwrite it."
        }
    }

    if ($showSourceReport) {
        show-installed-programs-check
    }

    if ($isDefaultManager) {
        $programs = @(show-installed-programs-hklm)
        if ($exportCsv) {
            if ($programs.Count -eq 0) {
                '"DisplayName","DisplayVersion","Publisher","InstallSource"' |
                    Set-Content -LiteralPath $resolvedCsvPath -Encoding UTF8
            }
            else {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    $programs | Export-Csv -LiteralPath $resolvedCsvPath -NoTypeInformation -Encoding UTF8
                }
                else {
                    $programs | Export-Csv -LiteralPath $resolvedCsvPath -Encoding UTF8
                }
            }
            Write-Output "Saved CSV to '$resolvedCsvPath'."
        }
        else {
            Format-InstalledProgramList -Programs $programs
        }
        return
    }

    switch ($Manager.ToLowerInvariant()) {
        'scoop' { show-installed-programs-scoop; return }
        'winget' { show-installed-programs-winget; return }
        { $_ -eq 'choco' -or $_ -eq 'chocolatey' } { show-installed-programs-choco; return }
        'pip' { Assert-PackageManagerAvailable -Name 'pip'; pip list --format=columns; return }
        'pipx' { Assert-PackageManagerAvailable -Name 'pipx'; pipx list; return }
        'npm' { Assert-PackageManagerAvailable -Name 'npm'; npm list -g --depth=0; return }
        'yarn' { Assert-PackageManagerAvailable -Name 'yarn'; yarn global list --depth=0; return }
        { $_ -eq 'cargo' -or $_ -eq '-cargo' } { Assert-PackageManagerAvailable -Name 'cargo'; cargo install --list; return }
        default {
            Write-Error "Unknown manager '$Manager'. Run 'listapps --help' for available managers."
        }
    }
}

# Create an alias for the function
Set-Alias listapps show-installed-programs #-Option AllScope