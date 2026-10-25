$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$markCoordinates = @(170,190, 512,515, 854,190, 854,760, 724,890, 724,472, 512,665, 300,472, 300,890, 170,760)

function New-MarkPath([int]$size) {
  $scale = $size / 1024.0
  $points = New-Object System.Drawing.PointF[] ([int]($markCoordinates.Count / 2))
  for ($i = 0; $i -lt $points.Length; $i++) {
    $points[$i] = [System.Drawing.PointF]::new([single]($markCoordinates[$i * 2] * $scale), [single]($markCoordinates[$i * 2 + 1] * $scale))
  }
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $path.AddPolygon($points)
  return $path
}

function New-MetalBrush([int]$size) {
  $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Rectangle]::new(0, 0, $size, $size), [System.Drawing.Color]::White, [System.Drawing.Color]::Gray, 42.0)
  $blend = [System.Drawing.Drawing2D.ColorBlend]::new()
  $blend.Colors = [System.Drawing.Color[]]@(
    [System.Drawing.Color]::FromArgb(255, 247, 248, 250), [System.Drawing.Color]::FromArgb(255, 150, 155, 161),
    [System.Drawing.Color]::FromArgb(255, 244, 246, 248), [System.Drawing.Color]::FromArgb(255, 101, 107, 114),
    [System.Drawing.Color]::FromArgb(255, 224, 227, 231), [System.Drawing.Color]::FromArgb(255, 129, 135, 142),
    [System.Drawing.Color]::FromArgb(255, 246, 247, 249)
  )
  $blend.Positions = [single[]]@(0.0, 0.16, 0.34, 0.51, 0.68, 0.84, 1.0)
  $brush.InterpolationColors = $blend
  return $brush
}

function Save-MosixMark([string]$path, [int]$size, [bool]$background, [string]$style) {
  $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.Clear([System.Drawing.Color]::Transparent)
  if ($background) {
    $black = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 3, 3, 4))
    $graphics.FillRectangle($black, 0, 0, $size, $size)
    $black.Dispose()
  }
  $mark = New-MarkPath $size
  if ($style -eq 'mono') {
    $fill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $graphics.FillPath($fill, $mark)
    $fill.Dispose()
  } else {
    $shadow = $mark.Clone()
    $matrix = [System.Drawing.Drawing2D.Matrix]::new()
    $matrix.Translate([single]($size * 0.008), [single]($size * 0.012))
    $shadow.Transform($matrix)
    $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(75, 0, 0, 0))
    $graphics.FillPath($shadowBrush, $shadow)
    $metal = New-MetalBrush $size
    $graphics.FillPath($metal, $mark)
    $edge = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(90, 255, 255, 255), [single][Math]::Max(1.0, $size * 0.003))
    $graphics.DrawPath($edge, $mark)
    $edge.Dispose()
    $metal.Dispose()
    $shadowBrush.Dispose()
    $matrix.Dispose()
    $shadow.Dispose()
  }
  $mark.Dispose()
  $graphics.Dispose()
  $parent = Split-Path -Parent $path
  if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
}

$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title"><title id="title">Mosix M mark</title><defs><linearGradient id="steel" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#f7f8fa"/><stop offset="16%" stop-color="#969ba1"/><stop offset="34%" stop-color="#f4f6f8"/><stop offset="51%" stop-color="#656b72"/><stop offset="68%" stop-color="#e0e3e7"/><stop offset="84%" stop-color="#81878e"/><stop offset="100%" stop-color="#f6f7f9"/></linearGradient><filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur stdDeviation="8"/></filter></defs><rect width="1024" height="1024" fill="#030304"/><path d="M170 190 512 515 854 190v570L724 890V472L512 665 300 472V890L170 760Z" fill="#000" opacity=".36" transform="translate(9 12)" filter="url(#shadow)"/><path d="M170 190 512 515 854 190v570L724 890V472L512 665 300 472V890L170 760Z" fill="url(#steel)" stroke="#f7f8fa" stroke-opacity=".32" stroke-width="3" stroke-linejoin="round"/><path d="m170 190 112 107 230 218v75L300 472v418L170 760Z" fill="#fff" opacity=".12"/><path d="m854 190-112 107-230 218v75l212-118v418l130-130Z" fill="#11151a" opacity=".17"/></svg>
"@
[System.IO.File]::WriteAllText((Join-Path $root 'logo.svg'), $svg, [System.Text.UTF8Encoding]::new($false))

Save-MosixMark (Join-Path $root 'icon.png') 2048 $true 'metal'
Save-MosixMark (Join-Path $root 'icon_android.png') 1024 $true 'metal'
Save-MosixMark (Join-Path $root 'icon_foreground_android.png') 1024 $false 'metal'
Save-MosixMark (Join-Path $root 'assets\images\logo.png') 2048 $true 'metal'
Save-MosixMark (Join-Path $root 'assets\images\logo-transparent.png') 2048 $false 'metal'

$androidSizes = @(
  @{dir='mipmap-mdpi'; size=48}, @{dir='mipmap-hdpi'; size=72}, @{dir='mipmap-xhdpi'; size=96},
  @{dir='mipmap-xxhdpi'; size=144}, @{dir='mipmap-xxxhdpi'; size=192}
)
foreach ($item in $androidSizes) { Save-MosixMark (Join-Path $root "android\app\src\main\res\$($item.dir)\ic_launcher.png") $item.size $true 'metal' }
$adaptiveSizes = @(
  @{dir='drawable-mdpi'; size=108}, @{dir='drawable-hdpi'; size=162}, @{dir='drawable-xhdpi'; size=216},
  @{dir='drawable-xxhdpi'; size=324}, @{dir='drawable-xxxhdpi'; size=432}
)
foreach ($item in $adaptiveSizes) {
  Save-MosixMark (Join-Path $root "android\app\src\main\res\$($item.dir)\ic_launcher_foreground.png") $item.size $false 'metal'
  Save-MosixMark (Join-Path $root "android\app\src\main\res\$($item.dir)\ic_launcher_monochrome.png") $item.size $false 'mono'
}
$contentsPath = Join-Path $root 'ios\Runner\Assets.xcassets\AppIcon.appiconset\Contents.json'
$contents = Get-Content -LiteralPath $contentsPath -Raw | ConvertFrom-Json
foreach ($item in $contents.images) {
  if (!$item.filename) { continue }
  $logicalSize = [double]::Parse(($item.size -split 'x')[0], [Globalization.CultureInfo]::InvariantCulture)
  $scale = [double]::Parse(($item.scale -replace 'x',''), [Globalization.CultureInfo]::InvariantCulture)
  $pixels = [int][Math]::Round($logicalSize * $scale)
  Save-MosixMark (Join-Path (Split-Path -Parent $contentsPath) $item.filename) $pixels $true 'metal'
}
'Generated Mosix M logo assets.'