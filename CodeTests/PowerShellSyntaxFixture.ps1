# PowerShell syntax highlighting fixture.
# Includes comments, strings, here-strings, hashtables, pipelines, classes, and errors.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $Name = 'Code Preview',

    [switch] $DryRun,

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug'
)

Set-StrictMode -Version Latest

$singleQuoted = 'literal $HOME "$(Get-Date)" `n text'
$doubleQuoted = "expanded user=$env:USER name=$Name config=$Configuration"
$escapedQuotes = "double quote: `" single quote: ' backtick: `` dollar: `$"
$subExpression = "today=$((Get-Date).ToString('yyyy-MM-dd'))"
$verbatimPath = 'C:\Program Files\Code Preview\app.exe'
$regex = '^(?<name>[A-Za-z][\w-]+)\s*=\s*(?<value>.+)$'

$singleHereString = @'
Single-quoted here-string.
$Name and $(Get-Date) stay literal.
"Double quotes" and 'single quotes' are ordinary text.
'@

$doubleHereString = @"
Double-quoted here-string.
Name: $Name
Config: $Configuration
Expression: $((Get-Location).Path)
"@

$items = @(
    'alpha',
    "beta-$Configuration",
    [pscustomobject]@{
        Name = 'gamma'
        Kind = 'object'
        Enabled = $true
    }
)

$settings = @{
    Name = $Name
    Configuration = $Configuration
    DryRun = [bool] $DryRun
    Path = $verbatimPath
    Nested = @{
        Single = $singleQuoted
        Double = $doubleQuoted
    }
}

class FixtureResult {
    [string] $Name
    [bool] $Succeeded

    FixtureResult([string] $name, [bool] $succeeded) {
        $this.Name = $name
        $this.Succeeded = $succeeded
    }

    [string] ToString() {
        return "{0}:{1}" -f $this.Name, $this.Succeeded
    }
}

function Write-FixtureLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Warn', 'Error')]
        [string] $Level,

        [Parameter(ValueFromPipeline = $true)]
        [string] $Message
    )

    process {
        Write-Output ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
    }
}

try {
    if ($DryRun.IsPresent) {
        'dry run enabled' | Write-FixtureLog -Level Info
    }
    elseif ($Name -match 'Preview') {
        "matched preview name: $Name" | Write-FixtureLog -Level Info
    }
    else {
        "plain name: $Name" | Write-FixtureLog -Level Warn
    }

    foreach ($item in $items) {
        switch ($item) {
            { $_ -is [string] -and $_ -like 'alpha' } {
                "string item: $_" | Write-FixtureLog -Level Info
                continue
            }
            { $_ -is [pscustomobject] } {
                "object item: $($_.Name)" | Write-FixtureLog -Level Info
                continue
            }
            default {
                "other item: $_" | Write-FixtureLog -Level Warn
            }
        }
    }

    $parsed = 'title = Markdown Preview' -replace $regex, '${name}:${value}'
    $json = $settings | ConvertTo-Json -Depth 4
    $result = [FixtureResult]::new($Name, $true)

    @(
        $singleQuoted
        $doubleQuoted
        $escapedQuotes
        $subExpression
        $singleHereString
        $doubleHereString
        $parsed
        $json
        $result.ToString()
    ) | ForEach-Object {
        $_ | Write-FixtureLog -Level Info
    }
}
catch [System.Exception] {
    "caught exception: $($_.Exception.Message)" | Write-FixtureLog -Level Error
    throw
}
finally {
    'fixture complete' | Write-FixtureLog -Level Info
}
