# ---------------------------------------------------------------
#  Adventure King - 备份存档
#
#  存档其实有两份，位置不一样：
#    1) 浏览器 localStorage   —— Ruffle 真正读写的那份（按 地址+端口 隔离）
#    2) 游戏目录下的 save.json —— 页面每 5 秒把 localStorage 镜像过来
#
#  所以本脚本会先找「正在运行的游戏服务」，直接把它当前那份镜像抓下来，
#  这样不管你是在哪个目录、哪个端口玩的，备份到的都是最新存档。
#  找不到服务时，退回到「本目录下的 save.json」。
#
#  备份结果放在 存档备份\<时间戳>\ ，同时刷新 存档备份\最新\ 。
# ---------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = Join-Path $root '存档备份'

function Write-Line([string]$t, [string]$c) {
    if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t }
}

# 取一个 URL 的原始字节（不走系统代理，避免 localhost 被代理拦截）
function Get-UrlBytes([string]$u) {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    try { return $wc.DownloadData($u) } finally { $wc.Dispose() }
}

# 在候选端口里找正在运行的游戏服务；返回端口号，找不到返回 0
function Find-GameServer {
    $cands = @()
    $cands += 8120..8135
    $cands += 8770..8820
    foreach ($p in $cands) {
        try {
            $bytes = Get-UrlBytes "http://127.0.0.1:$p/index.html"
            $html = [System.Text.Encoding]::UTF8.GetString($bytes)
            # 必须是我们这个游戏页（引了 ruffle.js，或标题里有「冒险王」），否则跳过
            if ($html -match 'ruffle/ruffle\.js' -or $html -match '冒险王') { return $p }
        } catch { }
    }
    return 0
}

Write-Host ""
Write-Line "  ===============================================" 'DarkYellow'
Write-Line "   冒险王之神兵传奇  -  备份存档" 'Yellow'
Write-Line "  ===============================================" 'DarkYellow'
Write-Host ""

# ---------- 1) 找正在跑的游戏服务，抓它当前的存档 ----------
$port = Find-GameServer
$liveText = $null
$liveFrom = '(没有正在运行的游戏服务)'

if ($port -gt 0) {
    $liveFrom = "http://127.0.0.1:$port/__save__"
    try {
        $bytes = Get-UrlBytes $liveFrom
        $liveText = [System.Text.Encoding]::UTF8.GetString($bytes).Trim()
        Write-Line "  找到正在运行的游戏服务：127.0.0.1:$port" 'Cyan'
    } catch {
        Write-Line "  [!] 服务在 127.0.0.1:$port，但读存档失败：$($_.Exception.Message)" 'Yellow'
    }
} else {
    Write-Line "  没有检测到正在运行的游戏服务，改用本目录的 save.json。" 'Gray'
}

$liveIsEmpty = ($null -eq $liveText) -or ($liveText -eq '') -or ($liveText -eq '{}')

# ---------- 2) 本目录的 save.json ----------
$localSave = Join-Path $root 'save.json'
$localText = $null
if (Test-Path -LiteralPath $localSave) {
    $localText = [System.IO.File]::ReadAllText($localSave, [System.Text.Encoding]::UTF8).Trim()
}

# ---------- 3) 选一份作为「这次要备份的存档」 ----------
$chosen = $null
$chosenFrom = ''
if (-not $liveIsEmpty) {
    $chosen = $liveText; $chosenFrom = $liveFrom
} elseif ($localText -and $localText -ne '{}') {
    $chosen = $localText; $chosenFrom = $localSave
}

if (-not $chosen) {
    Write-Line "  [!] 没有找到任何存档 —— 也就是说还没开始玩，或者存档已经被清掉了。" 'Yellow'
    Write-Host ""
    Write-Line "  如果你确实玩过、只是换个目录 / 换个端口玩的，请到那个目录里去备份。" 'Gray'
    Write-Host ""
    exit 0
}

# ---------- 4) 落盘 ----------
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$dst = Join-Path $base $stamp
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$dstSave = Join-Path $dst 'save.json'
[System.IO.File]::WriteAllText($dstSave, $chosen, (New-Object System.Text.UTF8Encoding($false)))

# 本目录 save.json 跟备份内容不一样时，额外留一份，便于对照
if ($localText -and $localText -ne $chosen) {
    [System.IO.File]::WriteAllText((Join-Path $dst 'save.json.本机副本'), $localText, (New-Object System.Text.UTF8Encoding($false)))
}

# 顺带把本目录里的其它存档痕迹也带上
$extra = @()
foreach ($name in @('save_state.json', 'game_save_post.txt', 'missing_assets.log')) {
    $p = Join-Path $root $name
    if (Test-Path -LiteralPath $p) {
        Copy-Item -LiteralPath $p -Destination (Join-Path $dst $name) -Force
        $extra += $name
    }
}

$latest = Join-Path $base '最新'
New-Item -ItemType Directory -Force -Path $latest | Out-Null
[System.IO.File]::WriteAllText((Join-Path $latest 'save.json'), $chosen, (New-Object System.Text.UTF8Encoding($false)))

# ---------- 5) 说明文件 ----------
$size = (Get-Item -LiteralPath $dstSave).Length
$md5 = (Get-FileHash -LiteralPath $dstSave -Algorithm MD5).Hash.ToLower()
$md5Local = '(无)'
if ($localText) { $md5Local = (Get-FileHash -LiteralPath $localSave -Algorithm MD5).Hash.ToLower() }

$info = @()
$info += "冒险王之神兵传奇  -  存档备份说明"
$info += "====================================="
$info += "备份时间  ：" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$info += "脚本目录  ：$root"
$info += "存档来源  ：$chosenFrom"
$info += "save.json ：$size 字节   md5=$md5"
$info += "本目录副本：md5=$md5Local"
$info += "附带备份  ：" + $(if ($extra.Count) { $extra -join ', ' } else { '（无）' })
$info += ""
$info += "【存档到底存在哪】"
$info += "  两份，位置不同："
$info += "   (1) 浏览器 localStorage —— Ruffle 真正读写的那份。"
$info += "       键名固定为 127.0.0.1/gameload.swf/shengbingchuanqi"
$info += "       它按「浏览器配置目录 + 地址（含端口）」隔离，换浏览器 / 换端口 = 存档看不到。"
$info += "       物理文件在  %LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Local Storage\leveldb\"
$info += "   (2) 游戏目录下的 save.json —— 页面每 5 秒把 (1) 镜像过来。"
$info += "       这份可以直接拷走。本文件夹里的 save.json 就是它。"
$info += ""
$info += "【怎么恢复】"
$info += "  1. 关掉游戏的浏览器标签页（服务窗口可以留着）；"
$info += "  2. 先双击 清空存档.bat 清一次（否则浏览器里的旧存档会盖回来）；"
$info += "  3. 把本文件夹里的 save.json 复制到游戏根目录（和 serve.ps1 同一层），覆盖同名文件；"
$info += "  4. 重新双击 开始游戏.bat，进游戏后选「继续游戏」。"
[System.IO.File]::WriteAllLines((Join-Path $dst '备份信息.txt'), $info, (New-Object System.Text.UTF8Encoding($false)))

Write-Line "  备份完成。" 'Green'
Write-Host ""
Write-Line "  存档来源 : $chosenFrom" 'Cyan'
Write-Line "  备份到   : $dst" 'Cyan'
Write-Line "  大小     : $size 字节   md5=$md5" 'Gray'
if ($extra.Count) { Write-Line "  附带备份 : $($extra -join ', ')" 'Gray' }
Write-Host ""
Write-Line "  另外也刷新了一份到 存档备份\最新\save.json" 'DarkGray'
Write-Host ""
