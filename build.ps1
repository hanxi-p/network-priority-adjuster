$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
Add-Type -AssemblyName System.Drawing
if (-not ('NetworkIconNative' -as [type])) {
    Add-Type 'using System; using System.Runtime.InteropServices; public static class NetworkIconNative { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon); }'
}
$images = @()
foreach ($size in @(16,24,32,48,64,128,256)) {
    $bitmap = New-Object Drawing.Bitmap($size,$size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.ScaleTransform($size/64.0,$size/64.0)
    $graphics.Clear([Drawing.Color]::Transparent)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(1,1,22,22,180,90); $path.AddArc(41,1,22,22,270,90)
    $path.AddArc(41,41,22,22,0,90); $path.AddArc(1,41,22,22,90,90); $path.CloseFigure()
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush([Drawing.Point]::new(0,0),[Drawing.Point]::new(64,64),[Drawing.Color]::FromArgb(31,117,225),[Drawing.Color]::FromArgb(15,75,168))
    $graphics.FillPath($brush,$path)
    $pen = New-Object Drawing.Pen([Drawing.Color]::White,3.5)
    $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    $graphics.DrawRectangle($pen,23,12,18,13)
    $graphics.DrawLine($pen,32,25,32,36)
    $graphics.DrawLine($pen,15,36,49,36)
    $graphics.DrawLine($pen,15,36,15,43)
    $graphics.DrawLine($pen,49,36,49,43)
    $graphics.DrawRectangle($pen,8,43,14,10)
    $graphics.DrawRectangle($pen,42,43,14,10)
    $handle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle)
    $memory = New-Object IO.MemoryStream
    $icon.Save($memory)
    $bytes = $memory.ToArray()
    $imageSize = [BitConverter]::ToUInt32($bytes,14)
    $imageOffset = [BitConverter]::ToUInt32($bytes,18)
    $images += ,@{size=$size; data=$bytes[$imageOffset..($imageOffset+$imageSize-1)]}
    $memory.Dispose(); $icon.Dispose(); [void][NetworkIconNative]::DestroyIcon($handle)
    $pen.Dispose();$brush.Dispose();$path.Dispose();$graphics.Dispose();$bitmap.Dispose()
}
$file = [IO.File]::Create((Join-Path $PSScriptRoot 'network.ico'))
$writer = New-Object IO.BinaryWriter($file)
$writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$images.Count)
$offset = 6+16*$images.Count
foreach ($image in $images) {
    $dimension = if($image.size -eq 256){0}else{$image.size}
    $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
    $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$image.data.Length);$writer.Write([uint32]$offset)
    $offset += $image.data.Length
}
foreach ($image in $images) { $writer.Write([byte[]]$image.data) }
$writer.Dispose();$file.Dispose()
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Path dist -Force | Out-Null
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /out:dist\网络优先级.exe /win32manifest:app.manifest /win32icon:network.ico /resource:index.html,index.html /resource:network.ps1,network.ps1 /resource:network.ico,network.ico /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll Program.cs
if ($LASTEXITCODE -ne 0) { throw 'EXE 编译失败' }
Get-Item -LiteralPath '.\dist\网络优先级.exe' | Select-Object FullName,Length,LastWriteTime
