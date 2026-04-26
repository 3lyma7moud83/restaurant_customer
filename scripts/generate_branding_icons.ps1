Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Get-AlphaBounds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap
    )

    $minX = $Bitmap.Width
    $minY = $Bitmap.Height
    $maxX = -1
    $maxY = -1

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if ($Bitmap.GetPixel($x, $y).A -gt 0) {
                if ($x -lt $minX) { $minX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }

    if ($maxX -lt 0 -or $maxY -lt 0) {
        throw "The source logo has no visible pixels (alpha only)."
    }

    return [System.Drawing.Rectangle]::FromLTRB($minX, $minY, $maxX + 1, $maxY + 1)
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
        if (-not (Test-Path -LiteralPath $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

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

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sourcePath = Join-Path $projectRoot "android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png"

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Source icon not found at $sourcePath"
}

$sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
$sourceStream = New-Object System.IO.MemoryStream(, $sourceBytes)
$source = [System.Drawing.Bitmap]::FromStream($sourceStream)
try {
    $trimBounds = Get-AlphaBounds -Bitmap $source
    $trimmed = $source.Clone($trimBounds, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $jobs = @(
            # Android launcher icons.
            @{ Path = "android\app\src\main\res\mipmap-mdpi\ic_launcher.png"; Size = 48; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "android\app\src\main\res\mipmap-hdpi\ic_launcher.png"; Size = 72; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "android\app\src\main\res\mipmap-xhdpi\ic_launcher.png"; Size = 96; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png"; Size = 144; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },

            # Android notification icons (white + transparent).
            @{ Path = "android\app\src\main\res\drawable-mdpi\ic_stat_notification.png"; Size = 24; Coverage = 0.72; Background = "transparent"; MonochromeWhite = $true },
            @{ Path = "android\app\src\main\res\drawable-hdpi\ic_stat_notification.png"; Size = 36; Coverage = 0.72; Background = "transparent"; MonochromeWhite = $true },
            @{ Path = "android\app\src\main\res\drawable-xhdpi\ic_stat_notification.png"; Size = 48; Coverage = 0.72; Background = "transparent"; MonochromeWhite = $true },
            @{ Path = "android\app\src\main\res\drawable-xxhdpi\ic_stat_notification.png"; Size = 72; Coverage = 0.72; Background = "transparent"; MonochromeWhite = $true },
            @{ Path = "android\app\src\main\res\drawable-xxxhdpi\ic_stat_notification.png"; Size = 96; Coverage = 0.72; Background = "transparent"; MonochromeWhite = $true },

            # Web icons.
            @{ Path = "web\favicon.png"; Size = 64; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "web\icons\Icon-192.png"; Size = 192; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "web\icons\Icon-512.png"; Size = 512; Coverage = 0.82; Background = "transparent"; MonochromeWhite = $false },
            @{ Path = "web\icons\Icon-maskable-192.png"; Size = 192; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
            @{ Path = "web\icons\Icon-maskable-512.png"; Size = 512; Coverage = 0.62; Background = "#FFF6EB"; MonochromeWhite = $false },
            @{ Path = "web\icons\Icon-splash-512.png"; Size = 512; Coverage = 0.56; Background = "#FFF6EB"; MonochromeWhite = $false },

            # Root web bundle icons (for static deploy output in repo root).
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

            # Android splash drawable branding image.
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
    $source.Dispose()
    $sourceStream.Dispose()
}
