# ---------------------------------------------------------------
#  Adventure King - offline static server
#
#  你不需要手动运行这个文件 —— 双击「开始游戏.bat」就行，它会调用这里。
#
#  它在做什么：在本机开一个"迷你网页服务器"，把这个文件夹当成小网站
#  发布出去。Ruffle（Flash 模拟器）的核心是一个 .wasm 文件，浏览器
#  规定它只能通过 http:// 加载，所以直接双击 index.html（file://）
#  会黑屏。这就是这个服务器存在的唯一理由。
#
#  两个前提，别搞混（缺一不可）：
#    1) 必须走 http://       —— 否则 .wasm 加载不了（浏览器规定）
#    2) 必须是"浏览器"       —— 浏览器提供 ExternalInterface 所需的
#                              "容器"。没有容器的宿主（flashplayer_sa.exe、
#                              Ruffle 桌面版）会在点「开始游戏」时抛
#                              Error #2067 卡住。详见 docs/开发记录.md §1.2。
#
#  127.0.0.1 = "这台电脑自己"（= localhost）。只在本机内部，
#  不联网、不占带宽、不改系统设置、不需要管理员权限、外人也连不上。
# ---------------------------------------------------------------
param(
    [int]$Port = 8777,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.mjs'  = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.xml'  = 'text/xml; charset=utf-8'
    '.wasm' = 'application/wasm'
    '.swf'  = 'application/x-shockwave-flash'
    '.mp3'  = 'audio/mpeg'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.ico'  = 'image/x-icon'
    '.txt'  = 'text/plain; charset=utf-8'
}

# ------------------------------------------------------------------
#  IMPORTANT: browser storage (and therefore your game save) is tied
#  to the exact address, port included. So we always try the SAME
#  port first - changing it would silently hide an existing save.
# ------------------------------------------------------------------
$preferred = $Port

function Test-ExistingServer([int]$p) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/index.html" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

$listener = New-Object System.Net.HttpListener
$started = $false

try {
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://127.0.0.1:$preferred/")
    $listener.Start()
    $started = $true
} catch {
    if (Test-ExistingServer $preferred) {
        Write-Host ""
        Write-Host "  A game server is ALREADY running on port $preferred." -ForegroundColor Yellow
        Write-Host "  Reusing it (your save lives there) instead of starting a second one." -ForegroundColor Yellow
        if (-not $NoOpen) { Start-Process "http://127.0.0.1:$preferred/index.html" }
        exit 0
    }
    for ($p = $preferred + 1; $p -lt ($preferred + 40); $p++) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://127.0.0.1:$p/")
            $listener.Start()
            $Port = $p
            $started = $true
            Write-Host ""
            Write-Host "  [!] Port $preferred was busy, so port $Port is being used." -ForegroundColor Yellow
            Write-Host "  [!] Game saves are tied to the address, so a different port" -ForegroundColor Yellow
            Write-Host "      means a fresh save. Close other copies first if you want" -ForegroundColor Yellow
            Write-Host "      to keep your progress." -ForegroundColor Yellow
            break
        } catch { }
    }
}
if (-not $started) { throw "No free port found near $preferred" }

$url = "http://127.0.0.1:$Port/index.html"
Write-Host ""
Write-Host "  ===============================================" -ForegroundColor DarkYellow
Write-Host "   冒险王之神兵传奇  -  离线版" -ForegroundColor Yellow
Write-Host "  ===============================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "  这个黑色窗口是「迷你网页服务器」，不要关掉它 ——" -ForegroundColor White
Write-Host "  关掉它 = 游戏服务停止 = 浏览器里的游戏打不开。" -ForegroundColor White
Write-Host ""
Write-Host "  它只在本机内部工作：不联网、不改系统设置、不需要管理员权限。" -ForegroundColor Gray
Write-Host "  （127.0.0.1 就是『这台电脑自己』的意思，不是创建什么 IP。）" -ForegroundColor DarkGray
Write-Host ""
Write-Host "   游戏地址 : $url" -ForegroundColor Cyan
Write-Host "   游戏目录 : $root" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  浏览器应该已经自动打开了。没打开的话，把上面那个地址复制到浏览器。" -ForegroundColor Gray
Write-Host "  玩完了：关掉浏览器标签页 → 再关掉这个窗口。" -ForegroundColor Gray
Write-Host ""

if (-not $NoOpen) { Start-Process $url }

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    try {
        $req  = $ctx.Request
        $resp = $ctx.Response

        # ---- save-file bridge ------------------------------------------------
        # The page mirrors its localStorage (where Ruffle keeps the game save)
        # to save.json next to this script, so progress survives a browser
        # profile change, a different browser, or a changed port.
        $savePath = Join-Path $root 'save.json'
        if ($req.Url.AbsolutePath -eq '/__save__') {
            if ($req.HttpMethod -eq 'POST') {
                $sr = New-Object System.IO.StreamReader($req.InputStream)
                $bodyText = $sr.ReadToEnd()
                $sr.Close()
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($savePath, $bodyText, $enc)
                $ok = [System.Text.Encoding]::UTF8.GetBytes('ok')
                $resp.ContentType = 'text/plain; charset=utf-8'
                $resp.ContentLength64 = $ok.Length
                $resp.OutputStream.Write($ok, 0, $ok.Length)
                $resp.OutputStream.Close()
                continue
            }
            if (Test-Path -LiteralPath $savePath) {
                $sb = [System.IO.File]::ReadAllBytes($savePath)
                $resp.ContentType = 'application/json; charset=utf-8'
                $resp.Headers.Add('Cache-Control', 'no-store')
                $resp.ContentLength64 = $sb.Length
                $resp.OutputStream.Write($sb, 0, $sb.Length)
                $resp.OutputStream.Close()
                continue
            }
            $resp.StatusCode = 404
            $resp.Close()
            continue
        }

        # ---- missing-asset report -------------------------------------------
        # index.html reports every resource it could not load, so the set of
        # files this game needs can be completed from real evidence instead of
        # guesswork. A missing file is what freezes the in-level progress bar.
        if ($req.Url.AbsolutePath -eq '/__missing__') {
            $sr = New-Object System.IO.StreamReader($req.InputStream)
            $bodyText = $sr.ReadToEnd()
            $sr.Close()
            $missPath = Join-Path $root 'missing_assets.log'
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($missPath, "$stamp  $bodyText`r`n", $enc)
            $ok = [System.Text.Encoding]::UTF8.GetBytes('ok')
            $resp.ContentType = 'text/plain; charset=utf-8'
            $resp.ContentLength64 = $ok.Length
            $resp.OutputStream.Write($ok, 0, $ok.Length)
            $resp.OutputStream.Close()
            continue
        }

        # The game POSTs its save data back to its own URL. Answer 200 so the
        # browser never navigates away and the game keeps running. We also keep
        # a copy of the payload, as a second, independent save backup.
        if ($req.HttpMethod -eq 'POST') {
            $sr = New-Object System.IO.StreamReader($req.InputStream)
            $bodyText = $sr.ReadToEnd()
            $sr.Close()
            if ($bodyText -match '(^|&)value=') {
                try {
                    $postPath = Join-Path $root 'game_save_post.txt'
                    $enc = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($postPath, $bodyText, $enc)
                } catch { }
            }
            $ok = [System.Text.Encoding]::UTF8.GetBytes('ok')
            $resp.ContentType = 'text/plain; charset=utf-8'
            $resp.ContentLength64 = $ok.Length
            $resp.OutputStream.Write($ok, 0, $ok.Length)
            $resp.OutputStream.Close()
            continue
        }

        $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
        $rel = $rel -replace '/', '\'

        $full = Join-Path $root $rel
        $fullResolved = [System.IO.Path]::GetFullPath($full)
        $rootResolved = [System.IO.Path]::GetFullPath($root)

        # path-traversal guard
        if (-not $fullResolved.StartsWith($rootResolved, [StringComparison]::OrdinalIgnoreCase)) {
            $resp.StatusCode = 403
            $resp.Close()
            continue
        }

        if (Test-Path -LiteralPath $fullResolved -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($fullResolved).ToLower()
            $ct  = $mime[$ext]
            if (-not $ct) { $ct = 'application/octet-stream' }
            $resp.ContentType = $ct
            $resp.Headers.Add('Cache-Control', 'no-cache')
            $bytes = [System.IO.File]::ReadAllBytes($fullResolved)
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            # no-store matters: browsers may heuristically cache a 404, which
            # would keep the game stuck on a file that is now actually present.
            # NOTE: with HttpListener the header must be added *before* the
            # status code is assigned, otherwise it gets dropped.
            try { $resp.Headers.Add('Cache-Control', 'no-store') } catch { }
            $resp.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $rel")
            $resp.ContentType = 'text/plain; charset=utf-8'
            $resp.ContentLength64 = $msg.Length
            $resp.OutputStream.Write($msg, 0, $msg.Length)
        }
        $resp.OutputStream.Close()
    } catch {
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch {}
    }
}

$listener.Stop()
