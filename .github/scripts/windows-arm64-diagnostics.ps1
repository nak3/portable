param(
    [Parameter(Mandatory = $true)]
    [string]$Generator,

    [Parameter(Mandatory = $true)]
    [string]$Perl
)

$ErrorActionPreference = "Stop"

$diagnosticsDir = Join-Path $PWD "arm64-diagnostics"
New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null
$logPath = Join-Path $diagnosticsDir "diagnostics.log"
$summaryPath = Join-Path $diagnosticsDir "summary.md"
$gateTests = @(
    "bn_mod_exp",
    "bn_mod_sqrt",
    "cmstest",
    "ecdhtest"
)
$testTimeoutSeconds = 60
$slowTestTimeoutSeconds = 180
$results = [System.Collections.Generic.List[object]]::new()

function Write-Diagnostic {
    param([string]$Message)

    $Message | Tee-Object -FilePath $logPath -Append | Write-Host
}

function Invoke-DiagnosticCommand {
    param(
        [string]$Description,
        [string]$Command,
        [string[]]$CommandArguments
    )

    Write-Diagnostic ""
    Write-Diagnostic "== $Description =="
    Write-Diagnostic "$Command $($CommandArguments -join ' ')"
    & $Command @CommandArguments 2>&1 |
        Tee-Object -FilePath $logPath -Append |
        ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    Write-Diagnostic "Exit code: $exitCode"

    return $exitCode
}

function Add-Result {
    param(
        [string]$Configuration,
        [string]$Stage,
        [int]$ExitCode
    )

    $results.Add([pscustomobject]@{
        Configuration = $Configuration
        Stage = $Stage
        ExitCode = $ExitCode
    })
}

function Invoke-DiagnosticGateTests {
    param(
        [string]$Configuration,
        [string]$BuildDirectory
    )

    $safeConfiguration = $Configuration -replace "[^A-Za-z0-9_.-]", "-"
    $escapedTests = $gateTests | ForEach-Object { [regex]::Escape($_) }
    $testRegex = "^($($escapedTests -join '|'))$"
    $exitCode = Invoke-DiagnosticCommand "$Configuration gate tests" "ctest" @(
        "--test-dir", $BuildDirectory,
        "-C", "Release",
        "-R", $testRegex,
        "--timeout", "$testTimeoutSeconds",
        "--output-on-failure",
        "--output-log", (Join-Path $diagnosticsDir "$safeConfiguration-gate.log")
    )
    Add-Result $Configuration "gate tests" $exitCode

    return $exitCode -eq 0
}

function Invoke-DiagnosticFullSuite {
    param(
        [string]$Configuration,
        [string]$BuildDirectory
    )

    $safeConfiguration = $Configuration -replace "[^A-Za-z0-9_.-]", "-"
    $exitCode = Invoke-DiagnosticCommand "$Configuration full test suite" "ctest" @(
        "--test-dir", $BuildDirectory,
        "-C", "Release",
        "--timeout", "$slowTestTimeoutSeconds",
        "--output-on-failure",
        "--output-log", (Join-Path $diagnosticsDir "$safeConfiguration-full.log")
    )
    Add-Result $Configuration "full test suite" $exitCode

    return $exitCode
}

function Test-Configuration {
    param(
        [string]$Name,
        [string]$BuildDirectory,
        [string[]]$AdditionalCMakeArguments,
        [switch]$VerboseBuild
    )

    $configureArguments = @(
        "-S", ".",
        "-B", $BuildDirectory,
        "-G", $Generator,
        "-A", "ARM64",
        "-D", "BUILD_SHARED_LIBS=OFF",
        "-D", "CMAKE_INSTALL_PREFIX=../local",
        "-D", "PERL_EXECUTABLE=$Perl"
    )
    if ($AdditionalCMakeArguments) {
        $configureArguments += $AdditionalCMakeArguments
    }
    $exitCode = Invoke-DiagnosticCommand "$Name configure" "cmake" $configureArguments
    Add-Result $Name "configure" $exitCode
    if ($exitCode -ne 0) {
        return $exitCode
    }

    $buildArguments = @(
        "--build", $BuildDirectory,
        "--config", "Release"
    )
    if ($VerboseBuild) {
        $buildArguments += "--verbose"
    }
    $exitCode = Invoke-DiagnosticCommand "$Name build" "cmake" $buildArguments
    Add-Result $Name "build" $exitCode
    if ($exitCode -ne 0) {
        return $exitCode
    }

    if (-not (Invoke-DiagnosticGateTests $Name $BuildDirectory)) {
        return 1
    }

    return Invoke-DiagnosticFullSuite $Name $BuildDirectory
}

Write-Diagnostic "Windows ARM64 diagnostics"
Write-Diagnostic "Generator: $Generator"
Write-Diagnostic "PROCESSOR_ARCHITECTURE: $env:PROCESSOR_ARCHITECTURE"
Write-Diagnostic "PROCESSOR_IDENTIFIER: $env:PROCESSOR_IDENTIFIER"
Write-Diagnostic "NUMBER_OF_PROCESSORS: $env:NUMBER_OF_PROCESSORS"

Invoke-DiagnosticCommand "Windows version" "cmd" @("/c", "ver") | Out-Null
Invoke-DiagnosticCommand "CMake version" "cmake" @("--version") | Out-Null

$processor = Get-CimInstance Win32_Processor |
    Select-Object Name, Manufacturer, Architecture, NumberOfCores,
        NumberOfLogicalProcessors
Write-Diagnostic ($processor | Format-List | Out-String)

$compilerFiles = Get-ChildItem -Path "build/CMakeFiles" -Filter CMakeCCompiler.cmake `
    -Recurse -ErrorAction SilentlyContinue
foreach ($compilerFile in $compilerFiles) {
    Write-Diagnostic "Compiler metadata: $($compilerFile.FullName)"
    Get-Content $compilerFile.FullName |
        Select-String "CMAKE_C_COMPILER_(ID|VERSION|ARCHITECTURE_ID)" |
        ForEach-Object { Write-Diagnostic $_.Line }
}

$diagnosticExitCode = Test-Configuration `
    -Name "MSVC optimized, mulw no inlining" `
    -BuildDirectory "build-bn-mulw-noinline" `
    -AdditionalCMakeArguments @("-D", "MSVC_ARM64_BN_MULW_NOINLINE=ON") `
    -VerboseBuild

$summary = @(
    "## Windows ARM64 diagnostic results",
    "",
    "| Configuration | Stage | Exit code |",
    "| --- | --- | ---: |"
)
foreach ($result in $results) {
    $summary += "| $($result.Configuration) | $($result.Stage) | $($result.ExitCode) |"
}
$summary += @(
    "",
    "Gate tests: ``$($gateTests -join ', ')``",
    "The full suite runs only when every gate test passes.",
    "Per-test timeout: $testTimeoutSeconds seconds ($slowTestTimeoutSeconds seconds for the full suite)",
    "",
    "The diagnostic step fails when configuration, build, gate tests, or the full suite fails."
)

$summary | Set-Content -Path $summaryPath
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}

Write-Diagnostic ""
Write-Diagnostic ($summary -join [Environment]::NewLine)

exit $diagnosticExitCode
