# ---------------------------------------------------------------
#  Adventure King - 清空存档
#
#  为什么不能只删 save.json：
#  存档其实有两份 ——
#    (1) 浏览器 localStorage 里那份（Ruffle 真正读写的，按 地址+端口 隔离）
#    (2) 镜像到游戏目录下的 save.json
#  只删 (2) 是没用的：浏览器里那份会在 5 秒内又把它写回来。
#  只有「在同一个地址下打开的页面」才有权限清掉 (1)。
#  所以本脚本会找到正在运行的游戏服务，打开 index.html?reset=1，
#  由那个页面同时清掉两份。
#
#  正确姿势：游戏服务开着，但游戏的浏览器标签页要关掉。
# ---------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Line([string]$t, [string]$c) {
    if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t }
}

# 不走系统代理，避免 localhost 被代理拦掉
function New-Client {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    return $wc
}

function Get-UrlBytes([string]$u) {
    $wc = New-Client
    try { return $wc.DownloadData($u) } finally { $wc.Dispose() }
}

function Find-GameServer {
    $cands = @()
    $cands += 8120..8135
    $cands += 8770..8820
    foreach ($p in $cands) {
        try {
            $bytes = Get-UrlBytes "http://127.0.0.1:$p/index.html"
            $html = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($html -match 'ruffle/ruffle\.js' -or $html -match '冒险王') { return $p }
        } catch { }
    }
    return 0
}

Write-Host ""
Write-Line "  ===============================================" 'DarkYellow'
Write-Line "   冒险王之神兵传奇  -  清空存档" 'Yellow'
Write-Line "  ===============================================" 'DarkYellow'
Write-Host ""

$found = Find-GameServer

if ($found -eq 0) {
    Write-Line "  [!] 没找到正在运行的游戏服务。" 'Yellow'
    Write-Host ""
    Write-Line "  清档必须满足两个条件，缺一不可：" 'Gray'
    Write-Line "    · 游戏服务还开着（就是那个黑色命令行窗口）" 'Gray'
    Write-Line "    · 游戏的浏览器标签页已经关掉了" 'Gray'
    Write-Host ""
    Write-Line "  正确顺序：" 'Cyan'
    Write-Line "    1) 双击 开始游戏.bat 把服务开起来" 'Cyan'
    Write-Line "    2) 把打开的浏览器游戏页面关掉（命令行窗口别关）" 'Cyan'
    Write-Line "    3) 再双击本文件" 'Cyan'
    Write-Host ""
    exit 1
}

$base = "http://127.0.0.1:$found"
Write-Line "  已找到游戏服务：端口 $found" 'Cyan'
Write-Host ""

# ---- 先把服务器上的镜像置空（顺手做掉，免得网页那边失败） ----
$serverCleared = $false
try {
    $wc = New-Client
    $wc.Headers.Add('Content-Type', 'application/json')
    $wc.UploadString("$base/__save__", 'POST', '{}') | Out-Null
    $wc.Dispose()
    $serverCleared = $true
    Write-Line "  服务器上的存档镜像已置空。" 'Green'
} catch {
    Write-Line "  [!] 置空服务器镜像失败：$($_.Exception.Message)" 'Yellow'
}

# ---- 再把本目录的 save.json 也置空（如果存在） ----
$localSave = Join-Path $root 'save.json'
if (Test-Path -LiteralPath $localSave) {
    [System.IO.File]::WriteAllText($localSave, '{}', (New-Object System.Text.UTF8Encoding($false)))
    Write-Line "  本目录 save.json 已置空。" 'Green'
}

Write-Host ""
Write-Line "  接下来打开清档页面，请在网页里点「确认清空存档」。" 'Yellow'
Write-Host ""
Write-Line "  ※ 动手之前请再确认一次：游戏的浏览器标签页已经关掉了。" 'Gray'
Write-Line "    如果游戏还开着，它会在几秒内把旧存档写回来，这次清档就白做了。" 'Gray'
Write-Host ""

Start-Process "$base/index.html?reset=1"
