Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Resolve-BackgroundColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Background
    )

    if ($Background -eq "transparent") {
        return [System.Drawing.Color]::Transparent
    }

    if ($Background -match '^#[0-9A-Fa-f]{6}$') {
        return [System.Drawing.ColorTranslator]::FromHtml($Background)
    }

    throw "Unsupported background value '$Background'. Use 'transparent' or '#RRGGBB'."
}

function Get-VisibleBounds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap,
        [int]$MinAlpha = 1
    )

    $minX = $Bitmap.Width
    $minY = $Bitmap.Height
    $maxX = -1
    $maxY = -1

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if ($Bitmap.GetPixel($x, $y).A -ge $MinAlpha) {
                if ($x -lt $minX) { $minX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }

    if ($maxX -lt 0 -or $maxY -lt 0) {
        throw "The source logo has no visible pixels."
    }

    return [System.Drawing.Rectangle]::FromLTRB($minX, $minY, $maxX + 1, $maxY + 1)
}

function Get-ColorDistance {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$ColorA,
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$ColorB
    )

    $dr = [int]$ColorA.R - [int]$ColorB.R
    $dg = [int]$ColorA.G - [int]$ColorB.G
    $db = [int]$ColorA.B - [int]$ColorB.B
    return [Math]::Sqrt(($dr * $dr) + ($dg * $dg) + ($db * $db))
}

function Cleanup-FlatCornerBackground {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap,
        [int]$CornerTolerance = 28,
        [int]$PixelTolerance = 24
    )

    $corners = @(
        $Bitmap.GetPixel(0, 0),
        $Bitmap.GetPixel($Bitmap.Width - 1, 0),
        $Bitmap.GetPixel(0, $Bitmap.Height - 1),
        $Bitmap.GetPixel($Bitmap.Width - 1, $Bitmap.Height - 1)
    )

    $hasTransparentCorner = $false
    foreach ($corner in $corners) {
        if ($corner.A -lt 10) {
            $hasTransparentCorner = $true
            break
        }
    }

    if ($hasTransparentCorner) {
        return $Bitmap.Clone(
            [System.Drawing.Rectangle]::FromLTRB(0, 0, $Bitmap.Width, $Bitmap.Height),
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
    }

    $maxCornerDistance = 0.0
    for ($i = 0; $i -lt $corners.Count; $i++) {
        for ($j = $i + 1; $j -lt $corners.Count; $j++) {
            $distance = Get-ColorDistance -ColorA $corners[$i] -ColorB $corners[$j]
            if ($distance -gt $maxCornerDistance) {
                $maxCornerDistance = $distance
            }
        }
    }

    if ($maxCornerDistance -gt $CornerTolerance) {
        return $Bitmap.Clone(
            [System.Drawing.Rectangle]::FromLTRB(0, 0, $Bitmap.Width, $Bitmap.Height),
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
    }

    $avgR = [int][Math]::Round(($corners | ForEach-Object { $_.R } | Measure-Object -Average).Average)
    $avgG = [int][Math]::Round(($corners | ForEach-Object { $_.G } | Measure-Object -Average).Average)
    $avgB = [int][Math]::Round(($corners | ForEach-Object { $_.B } | Measure-Object -Average).Average)
    $background = [System.Drawing.Color]::FromArgb(255, $avgR, $avgG, $avgB)

    $result = New-Object System.Drawing.Bitmap($Bitmap.Width, $Bitmap.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $pixel = $Bitmap.GetPixel($x, $y)
            if ($pixel.A -eq 0) {
                continue
            }

            $distance = Get-ColorDistance -ColorA $pixel -ColorB $background
            if ($distance -le $PixelTolerance) {
                continue
            }

            $result.SetPixel($x, $y, $pixel)
        }
    }

    return $result
}

function Convert-ToWhiteAlpha {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap
    )

    $result = New-Object System.Drawing.Bitmap($Bitmap.Width, $Bitmap.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $pixel = $Bitmap.GetPixel($x, $y)
            if ($pixel.A -gt 0) {
                $result.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($pixel.A, 255, 255, 255))
            }
        }
    }
    return $result
}

function Save-Icon {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$TrimmedSource,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$Size,
        [Parameter(Mandatory = $true)]
        [double]$Coverage,
        [Parameter(Mandatory = $true)]
        [string]$Background,
        [double]$YOffset = 0.0,
        [bool]$MonochromeWhite = $false
    )

    $drawSource = $TrimmedSource
    if ($MonochromeWhite) {
        $drawSource = Convert-ToWhiteAlpha -Bitmap $TrimmedSource
    }

    try {
        $outputDir = Split-Path -Parent $Path
        Ensure-Directory -Path $outputDir

        $canvas = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($canvas)
            try {
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.Clear((Resolve-BackgroundColor -Background $Background))

                $targetSide = [Math]::Max(1, [int][Math]::Round($Size * $Coverage))
                $scale = [Math]::Min($targetSide / [double]$drawSource.Width, $targetSide / [double]$drawSource.Height)
                $targetWidth = [Math]::Max(1, [int][Math]::Round($drawSource.Width * $scale))
                $targetHeight = [Math]::Max(1, [int][Math]::Round($drawSource.Height * $scale))
                $targetX = [int][Math]::Floor(($Size - $targetWidth) / 2.0)
                $targetY = [int][Math]::Floor((($Size - $targetHeight) / 2.0) + ($Size * $YOffset))

                $destRect = New-Object System.Drawing.Rectangle($targetX, $targetY, $targetWidth, $targetHeight)
                $graphics.DrawImage($drawSource, $destRect)
            }
            finally {
                $graphics.Dispose()
            }

            if ($MonochromeWhite) {
                for ($y = 0; $y -lt $canvas.Height; $y++) {
                    for ($x = 0; $x -lt $canvas.Width; $x++) {
                        $pixel = $canvas.GetPixel($x, $y)
                        if ($pixel.A -gt 0) {
                            $canvas.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($pixel.A, 255, 255, 255))
                        }
                    }
                }
            }

            $canvas.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $canvas.Dispose()
        }
    }
    finally {
        if ($MonochromeWhite -and $drawSource -ne $null) {
            $drawSource.Dispose()
        }
    }
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $outputDir = Split-Path -Parent $Path
    Ensure-Directory -Path $outputDir
    Set-Content -Path $Path -Value $Content -Encoding UTF8
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sourcePath = Join-Path $projectRoot "assets\branding\delivery-mat3mk-transparent.png"

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Branding master source not found at $sourcePath"
}

$sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
$sourceStream = New-Object System.IO.MemoryStream(, $sourceBytes)
$source = [System.Drawing.Bitmap]::FromStream($sourceStream)
try {
    $cleaned = Cleanup-FlatCornerBackground -Bitmap $source
    try {
        $trimBounds = Get-VisibleBounds -Bitmap $cleaned -MinAlpha 4
        $trimmed = $cleaned.Clone($trimBounds, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $jobs = @(
                # Android legacy launcher icons.
                @{ Path = "android\app\src\main\res\mipmap-mdpi\ic_launcher.png"; Size = 48; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-hdpi\ic_launcher.png"; Size = 72; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xhdpi\ic_launcher.png"; Size = 96; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png"; Size = 144; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-mdpi\ic_launcher_round.png"; Size = 48; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-hdpi\ic_launcher_round.png"; Size = 72; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xhdpi\ic_launcher_round.png"; Size = 96; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xxhdpi\ic_launcher_round.png"; Size = 144; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_round.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },

                # Adaptive icon foreground layers (108dp canvas across densities, 66dp safe-zone content).
                @{ Path = "android\app\src\main\res\drawable-mdpi\ic_launcher_foreground.png"; Size = 108; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\drawable-hdpi\ic_launcher_foreground.png"; Size = 162; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\drawable-xhdpi\ic_launcher_foreground.png"; Size = 216; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\drawable-xxhdpi\ic_launcher_foreground.png"; Size = 324; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "android\app\src\main\res\drawable-xxxhdpi\ic_launcher_foreground.png"; Size = 432; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $false },

                # Adaptive icon monochrome layers (Android 13 themed icons).
                @{ Path = "android\app\src\main\res\drawable-mdpi\ic_launcher_monochrome.png"; Size = 108; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-hdpi\ic_launcher_monochrome.png"; Size = 162; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xhdpi\ic_launcher_monochrome.png"; Size = 216; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xxhdpi\ic_launcher_monochrome.png"; Size = 324; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xxxhdpi\ic_launcher_monochrome.png"; Size = 432; Coverage = 0.61; Background = "transparent"; MonochromeWhite = $true },

                # Android notification icons (small icon, monochrome white + transparent).
                @{ Path = "android\app\src\main\res\drawable-mdpi\ic_stat_notification.png"; Size = 24; Coverage = 0.68; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-hdpi\ic_stat_notification.png"; Size = 36; Coverage = 0.68; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xhdpi\ic_stat_notification.png"; Size = 48; Coverage = 0.68; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xxhdpi\ic_stat_notification.png"; Size = 72; Coverage = 0.68; Background = "transparent"; MonochromeWhite = $true },
                @{ Path = "android\app\src\main\res\drawable-xxxhdpi\ic_stat_notification.png"; Size = 96; Coverage = 0.68; Background = "transparent"; MonochromeWhite = $true },

                # Web icons.
                @{ Path = "web\favicon.png"; Size = 64; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "web\icons\Icon-192.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "web\icons\Icon-512.png"; Size = 512; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "web\icons\Icon-maskable-192.png"; Size = 192; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
                @{ Path = "web\icons\Icon-maskable-512.png"; Size = 512; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
                @{ Path = "web\icons\Icon-splash-512.png"; Size = 512; Coverage = 0.56; Background = "#FFF6EB"; MonochromeWhite = $false },

                # Root static web bundle icons.
                @{ Path = "favicon.png"; Size = 64; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "icons\Icon-192.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "icons\Icon-512.png"; Size = 512; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "icons\Icon-maskable-192.png"; Size = 192; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
                @{ Path = "icons\Icon-maskable-512.png"; Size = 512; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
                @{ Path = "icons\Icon-splash-512.png"; Size = 512; Coverage = 0.56; Background = "#FFF6EB"; MonochromeWhite = $false },

                # Branding exports.
                @{ Path = "assets\branding\delivery-mat3mk-transparent.png"; Size = 1024; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
                @{ Path = "assets\branding\delivery-mat3mk-solid.png"; Size = 1024; Coverage = 0.82; Background = "#FFF6EB"; MonochromeWhite = $false },
                @{ Path = "assets\branding\delivery-mat3mk-splash-ready.png"; Size = 1024; Coverage = 0.56; Background = "#FFF6EB"; MonochromeWhite = $false },

                # Android launch branding image.
                @{ Path = "android\app\src\main\res\drawable\launch_branding.png"; Size = 512; Coverage = 0.56; Background = "transparent"; MonochromeWhite = $false }
            )

            foreach ($job in $jobs) {
                $absolutePath = Join-Path $projectRoot $job.Path
                Save-Icon `
                    -TrimmedSource $trimmed `
                    -Path $absolutePath `
                    -Size $job.Size `
                    -Coverage $job.Coverage `
                    -Background $job.Background `
                    -MonochromeWhite $job.MonochromeWhite
                Write-Output "Generated $($job.Path)"
            }
        }
        finally {
            $trimmed.Dispose()
        }
    }
    finally {
        $cleaned.Dispose()
    }
}
finally {
    $source.Dispose()
    $sourceStream.Dispose()
}

$adaptiveIconXml = @"
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"@

$colorsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FFF6EB</color>
</resources>
"@

Write-TextFile -Path (Join-Path $projectRoot "android\app\src\main\res\mipmap-anydpi-v26\ic_launcher.xml") -Content $adaptiveIconXml
Write-TextFile -Path (Join-Path $projectRoot "android\app\src\main\res\mipmap-anydpi-v26\ic_launcher_round.xml") -Content $adaptiveIconXml
Write-TextFile -Path (Join-Path $projectRoot "android\app\src\main\res\values\colors.xml") -Content $colorsXml

Write-Output "Generated adaptive icon XML and launcher background color resources."
