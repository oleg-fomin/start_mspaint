<#
.SYNOPSIS
    Generate the placeholder logo PNGs that AppxManifest.xml references so the
    package can be packed. Replace these with real branded assets for release;
    only the pixel dimensions matter to the packer.
#>
param(
    [Parameter(Mandatory)] [string] $OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# name -> width x height required by the manifest VisualElements.
$assets = @{
    'StoreLogo.png'        = @(50,  50)
    'Square150x150Logo.png'= @(150, 150)
    'Square44x44Logo.png'  = @(44,  44)
    'SmallTile.png'        = @(71,  71)
}

foreach ($name in $assets.Keys) {
    $w, $h = $assets[$name]
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 0, 120, 215))  # solid brand blue
    $g.Dispose()
    $path = Join-Path $OutDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

Write-Host "[OK] Generated $($assets.Count) placeholder assets in $OutDir"
