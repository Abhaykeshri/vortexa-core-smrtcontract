param(
    [Parameter(Mandatory = $true)]
    [string] $IsolatedRoot,
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [string] $CampaignRoot = "test-reports\M10-Security-20261026\mutation-campaign",
    [int] $FuzzRuns = 256
)

$ErrorActionPreference = "Stop"
$repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$isolated = (Resolve-Path -LiteralPath $IsolatedRoot).Path
$campaign = (Resolve-Path -LiteralPath (Join-Path $repository $CampaignRoot)).Path

if ($isolated -eq $repository) {
    throw "Mutation tests require an isolated clone; refusing to mutate the working repository."
}
if (-not (Test-Path -LiteralPath (Join-Path $isolated ".git"))) {
    throw "IsolatedRoot must be a Git clone."
}

$testPatterns = @{
    "Vault" = @("test/unit/Vault*.t.sol", "test/attack/Vault*.t.sol", "test/fuzz/VaultFuzz.t.sol", "test/integration/Vault*.t.sol")
    "PriceGuard" = @("test/unit/PriceGuard*.t.sol", "test/attack/PriceGuard*.t.sol", "test/fuzz/PriceGuardFuzz.t.sol")
    "SwapExecutor" = @("test/unit/SwapExecutor.t.sol")
    "strategies-StrategyBase" = @("test/unit/Strategies.t.sol", "test/integration/M7StrategiesRealV4.t.sol")
    "strategies-NormalLPStrategy" = @("test/unit/Strategies.t.sol", "test/integration/M7StrategiesRealV4.t.sol")
    "strategies-BuyTheDipStrategy" = @("test/unit/Strategies.t.sol", "test/integration/M7StrategiesRealV4.t.sol")
    "strategies-SellThePumpStrategy" = @("test/unit/Strategies.t.sol", "test/integration/M7StrategiesRealV4.t.sol")
}

$results = [System.Collections.Generic.List[object]]::new()
$logPath = Join-Path $campaign "mutation-test.log"
"M10 mutation campaign started $(Get-Date -Format o)" | Set-Content -LiteralPath $logPath -Encoding utf8

foreach ($manifestPath in Get-ChildItem -LiteralPath $campaign -Filter "gambit_results.json" -Recurse | Sort-Object FullName) {
    $target = Split-Path -Leaf (Split-Path -Parent $manifestPath.FullName)
    if (-not $testPatterns.ContainsKey($target)) {
        throw "No test selection configured for mutation target $target"
    }

    foreach ($mutant in (Get-Content -LiteralPath $manifestPath.FullName -Raw | ConvertFrom-Json)) {
        $mutantPath = Join-Path (Split-Path -Parent $manifestPath.FullName) $mutant.name
        $relativeOriginal = $mutant.original -replace "\\", "/"
        $isolatedOriginal = Join-Path $isolated $relativeOriginal
        $killed = $false
        $killedBy = ""

        try {
            Copy-Item -LiteralPath $mutantPath -Destination $isolatedOriginal -Force
            foreach ($pattern in $testPatterns[$target]) {
                "[$target/$($mutant.id)] forge test --match-path $pattern" |
                    Add-Content -LiteralPath $logPath -Encoding utf8
                & forge test --root $isolated --profile default --match-path $pattern --fuzz-runs $FuzzRuns -q *>&1 |
                    Add-Content -LiteralPath $logPath -Encoding utf8
                if ($LASTEXITCODE -ne 0) {
                    $killed = $true
                    $killedBy = $pattern
                    break
                }
            }
        }
        finally {
            & git -C $isolated checkout -- $relativeOriginal
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to restore $relativeOriginal in isolated clone."
            }
        }

        $outcome = if ($killed) { "killed" } else { "survived" }
        $results.Add([pscustomobject]@{
            target = $target
            mutant_id = $mutant.id
            operator = $mutant.description
            outcome = $outcome
            killed_by = $killedBy
        })
        Write-Output "$target/$($mutant.id): $outcome $killedBy"
    }
}

$csvPath = Join-Path $campaign "mutation-results.csv"
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation
$total = $results.Count
$killedCount = @($results | Where-Object outcome -eq "killed").Count
$score = if ($total -eq 0) { 0 } else { 100 * $killedCount / $total }
$summary = "Killed $killedCount/$total mutants ({0:N2}%)." -f $score
$summary | Set-Content -LiteralPath (Join-Path $campaign "mutation-summary.txt") -Encoding utf8
Write-Output $summary
if ($score -lt 85) {
    throw "$summary Required score is at least 85%."
}
