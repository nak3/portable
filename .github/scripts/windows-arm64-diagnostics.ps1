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
$targetTests = @(
    "bn_test",
    "bn_mod_exp",
    "bn_mod_sqrt",
    "bn_primes",
    "cmstest",
    "cttest",
    "ecc_cdh",
    "ec_asn1_test",
    "ec_point_conversion",
    "ecdhtest",
    "ecdsatest",
    "ectest",
    "pkcs7test",
    "policy",
    "renegotiation_test",
    "rsa_method_test",
    "rsa_test"
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

function Invoke-DiagnosticTests {
    param(
        [string]$Configuration,
        [string]$BuildDirectory
    )

    foreach ($testName in $targetTests) {
        $safeConfiguration = $Configuration -replace "[^A-Za-z0-9_.-]", "-"
        $safeTestName = $testName -replace "[^A-Za-z0-9_.-]", "-"
        $timeoutSeconds = if ($testName -eq "bn_primes") {
            $slowTestTimeoutSeconds
        } else {
            $testTimeoutSeconds
        }
        $exitCode = Invoke-DiagnosticCommand "$Configuration test: $testName" "ctest" @(
            "--test-dir", $BuildDirectory,
            "-C", "Release",
            "-R", "^$([regex]::Escape($testName))$",
            "--timeout", "$timeoutSeconds",
            "--output-on-failure",
            "--output-log", (Join-Path $diagnosticsDir "$safeConfiguration-$safeTestName.log")
        )
        Add-Result $Configuration "test: $testName" $exitCode
    }
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
}

function Test-Configuration {
    param(
        [string]$Name,
        [string]$BuildDirectory,
        [string]$Toolset,
        [string]$ReleaseFlags,
        [string[]]$AdditionalCMakeArguments,
        [ValidateSet("ON", "OFF")]
        [string]$Shared = "OFF",
        [switch]$FullSuite,
        [switch]$VerboseBuild
    )

    $configureArguments = @(
        "-S", ".",
        "-B", $BuildDirectory,
        "-G", $Generator,
        "-A", "ARM64",
        "-D", "BUILD_SHARED_LIBS=$Shared",
        "-D", "CMAKE_INSTALL_PREFIX=../local",
        "-D", "PERL_EXECUTABLE=$Perl"
    )
    if ($Toolset) {
        $configureArguments += @("-T", $Toolset)
    }
    if ($ReleaseFlags) {
        $configureArguments += @("-D", "CMAKE_C_FLAGS_RELEASE=$ReleaseFlags")
    }
    if ($AdditionalCMakeArguments) {
        $configureArguments += $AdditionalCMakeArguments
    }
    $exitCode = Invoke-DiagnosticCommand "$Name configure" "cmake" $configureArguments
    Add-Result $Name "configure" $exitCode
    if ($exitCode -ne 0) {
        return
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
        return
    }

    if ($FullSuite) {
        Invoke-DiagnosticFullSuite $Name $BuildDirectory
    } else {
        Invoke-DiagnosticTests $Name $BuildDirectory
    }
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

Invoke-DiagnosticTests "MSVC optimized" "build"

Test-Configuration "MSVC no optimization" "build-noopt" "" "/Od /Ob0 /DNDEBUG"
Test-Configuration `
    -Name "MSVC optimized, bn_mont no inlining" `
    -BuildDirectory "build-bn-mont-noinline" `
    -AdditionalCMakeArguments @("-D", "MSVC_ARM64_BN_MONT_NOINLINE=ON") `
    -FullSuite
Test-Configuration `
    -Name "MSVC shared, bn_mont no inlining" `
    -BuildDirectory "build-shared-bn-mont-noinline" `
    -Shared "ON" `
    -AdditionalCMakeArguments @("-D", "MSVC_ARM64_BN_MONT_NOINLINE=ON") `
    -FullSuite
Test-Configuration `
    -Name "MSVC optimized, mulw addw addw no inlining" `
    -BuildDirectory "build-bn-mulw-addw-addw-noinline" `
    -AdditionalCMakeArguments @("-D", "MSVC_ARM64_BN_MULW_ADDW_ADDW_NOINLINE=ON") `
    -FullSuite `
    -VerboseBuild
Test-Configuration "ClangCL optimized" "build-clangcl" "ClangCL" ""

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
    "Targeted tests: ``$($targetTests -join ', ')``",
    "Per-test timeout: $testTimeoutSeconds seconds ($slowTestTimeoutSeconds seconds for bn_primes)",
    "",
    "A zero exit code means that the stage succeeded. Diagnostic failures do not stop subsequent comparisons."
)

$summary | Set-Content -Path $summaryPath
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}

Write-Diagnostic ""
Write-Diagnostic ($summary -join [Environment]::NewLine)

# This step is diagnostic only. The regular test step remains authoritative.
exit 0
