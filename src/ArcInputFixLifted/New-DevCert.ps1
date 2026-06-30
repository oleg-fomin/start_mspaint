<#
.SYNOPSIS
    Dev/test signing for ArcInputFixLifted.msix using a self-signed certificate
    whose subject matches the package manifest Publisher. NOT for fleet release -
    use a real code-signing cert (build.cmd SIGN_PFX) for that.

.DESCRIPTION
    1. Reads the Publisher (subject) from AppxManifest.xml.
    2. Creates (or reuses) a self-signed code-signing cert with that exact subject
       in CurrentUser\My.
    3. Signs the package with signtool.
    4. Exports the public cert to <OutDir>\ArcInputFixLifted.cer so the test
       machine can trust it (Import into LocalMachine\TrustedPeople) before the
       MSIX will register.
#>
param(
    [Parameter(Mandatory)] [string] $Manifest,
    [Parameter(Mandatory)] [string] $OutDir,
    [Parameter(Mandatory)] [string] $SignTool,
    [Parameter(Mandatory)] [string] $Package
)

$ErrorActionPreference = 'Stop'

[xml]$xml = Get-Content -LiteralPath $Manifest
$publisher = $xml.Package.Identity.Publisher
if ([string]::IsNullOrWhiteSpace($publisher)) {
    throw "Could not read Identity/Publisher from $Manifest."
}

# Reuse an existing matching cert if present, else create one.
$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey } |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "[*] Creating self-signed dev cert: $publisher"
    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $publisher `
        -KeyUsage DigitalSignature `
        -FriendlyName 'ArcInputFixLifted Dev Signing' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
} else {
    Write-Host "[*] Reusing existing dev cert: $($cert.Thumbprint)"
}

# Sign the package with the dev cert (by thumbprint).
& $SignTool sign /fd SHA256 /sha1 $cert.Thumbprint $Package
if ($LASTEXITCODE -ne 0) {
    throw "signtool sign failed with exit code $LASTEXITCODE."
}

# Export the public cert so the test machine can trust it.
$cerPath = Join-Path $OutDir 'ArcInputFixLifted.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

Write-Host "[OK] Dev-signed $Package"
Write-Host "[OK] Exported public cert -> $cerPath"
Write-Host "     On the test machine (elevated), trust it once with:"
Write-Host "       Import-Certificate -FilePath ArcInputFixLifted.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
