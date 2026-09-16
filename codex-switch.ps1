#Requires -Version 5.1
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Target
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = $OutputEncoding } catch {}
$Version = '1.0.0'
$CodexDir = Join-Path $env:USERPROFILE '.codex'
$AuthFile = Join-Path $CodexDir 'auth.json'
$StoreDir = Join-Path $CodexDir 'codex-switch'
$AccountsFile = Join-Path $StoreDir 'accounts.json'
$BackupDir = Join-Path $StoreDir 'backups'
$SessionDir = Join-Path $CodexDir 'sessions'

function Initialize-Store {
    foreach ($dir in @($StoreDir, $BackupDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    if (-not (Test-Path -LiteralPath $AccountsFile)) {
        $legacy = Join-Path (Join-Path $CodexDir 'codex-switch-app') (Join-Path 'config' 'accounts.json')
        if (Test-Path -LiteralPath $legacy) {
            Copy-Item -LiteralPath $legacy -Destination $AccountsFile -Force
        }
        else {
            [IO.File]::WriteAllText($AccountsFile, '{}', [Text.UTF8Encoding]::new($false))
        }
    }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ('.{0}.tmp-{1}' -f (Split-Path $Path -Leaf), $PID)
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Copy-Atomic([string]$Source, [string]$Destination) {
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ('.{0}.tmp-{1}' -f (Split-Path $Destination -Leaf), $PID)
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Get-JwtPayload([string]$Jwt) {
    if ([string]::IsNullOrWhiteSpace($Jwt)) { return $null }
    $parts = $Jwt.Split('.')
    if ($parts.Length -lt 2) { return $null }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) {
        2 { $p += '==' }
        3 { $p += '=' }
    }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-AuthDetails($Auth) {
    $idToken = $null
    if ($Auth -and $Auth.tokens) { $idToken = [string]$Auth.tokens.id_token }
    $payload = Get-JwtPayload $idToken
    $plan = 'unknown'
    if ($payload) {
        $oa = $payload.'https://api.openai.com/auth'
        if ($oa -and $oa.chatgpt_plan_type) { $plan = [string]$oa.chatgpt_plan_type }
    }
    $accountId = ''
    if ($Auth -and $Auth.tokens) { $accountId = [string]$Auth.tokens.account_id }
    [pscustomobject]@{
        Email        = $(if ($payload -and $payload.email) { [string]$payload.email } else { '' })
        Plan         = $plan
        AccountId    = $accountId
        LastRefresh  = $(if ($Auth) { [string]$Auth.last_refresh } else { '' })
    }
}

function Get-CurrentAuthDetails {
    $auth = Read-JsonFile $AuthFile
    if (-not $auth) { return $null }
    return Get-AuthDetails $auth
}

function Get-Accounts {
    Initialize-Store
    $obj = Read-JsonFile $AccountsFile
    $map = [ordered]@{}
    if ($obj) {
        foreach ($p in $obj.PSObject.Properties) {
            $v = $p.Value
            if (-not $v) { continue }
            $email = $(if ($v.email) { [string]$v.email } else { $p.Name })
            $map[$p.Name] = @{
                email        = $email
                plan         = $(if ($v.plan) { [string]$v.plan } else { 'unknown' })
                account_id   = [string]$v.account_id
                last_refresh = [string]$v.last_refresh
                saved_at     = [string]$v.saved_at
                legacy_names = @($(if ($v.legacy_names) { @($v.legacy_names) } else { @() }))
            }
        }
    }
    if ($map.Count -eq 0) {
        Get-ChildItem -LiteralPath $StoreDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'backups' -and $_.Name -like '*@*' } |
            ForEach-Object {
                $snap = Join-Path $_.FullName 'auth.json'
                if (-not (Test-Path -LiteralPath $snap)) { return }
                $details = Get-AuthDetails (Read-JsonFile $snap)
                $key = $(if ($details.Email) { $details.Email } else { $_.Name })
                $map[$key] = @{
                    email        = $key
                    plan         = $details.Plan
                    account_id   = $details.AccountId
                    last_refresh = $details.LastRefresh
                    saved_at     = $_.LastWriteTime.ToString('s')
                    legacy_names = @()
                }
            }
        if ($map.Count -gt 0) { Save-Accounts $map }
    }
    return $map
}

function Save-Accounts($Accounts) {
    Initialize-Store
    if ($Accounts.Count -eq 0) {
        [IO.File]::WriteAllText($AccountsFile, '{}', [Text.UTF8Encoding]::new($false))
        return
    }
    Write-JsonFile $AccountsFile ([pscustomobject]$Accounts)
}

function Get-SafeDirName([string]$Name) {
    ($Name -replace '[<>:"/\\|?*]', '_')
}

function Get-AccountAuthPath([string]$Key, $Data) {
    $names = @($Key)
    if ($Data.email -and $Data.email -ne $Key) { $names += [string]$Data.email }
    foreach ($legacy in @($Data.legacy_names)) {
        if ($legacy) { $names += [string]$legacy }
    }
    foreach ($name in $names) {
        $path = Join-Path (Join-Path $StoreDir (Get-SafeDirName $name)) 'auth.json'
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return Join-Path (Join-Path $StoreDir (Get-SafeDirName $Key)) 'auth.json'
}

function Backup-CurrentAuth([string]$Reason) {
    if (-not (Test-Path -LiteralPath $AuthFile)) { return $null }
    Initialize-Store
    $safe = $Reason -replace '[^A-Za-z0-9_-]', '-'
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
    $name = 'auth-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safe
    $dest = Join-Path $BackupDir $name
    Copy-Item -LiteralPath $AuthFile -Destination $dest -Force
    return $dest
}

function Show-RestartHint {
    Write-Host '账号文件已更新。工具不会启动、停止或修改 Codex/ChatGPT 桌面端。' -ForegroundColor Yellow
    Write-Host '请完全关闭并重新打开 Codex/ChatGPT 桌面端，让账号切换生效。' -ForegroundColor Yellow
}

function Get-WindowLabel($Minutes) {
    if ($null -eq $Minutes -or $Minutes -eq '') { return 'Unknown' }
    $n = [double]$Minutes
    if ($n -ge 10080) { return 'Weekly' }
    if ($n -ge 240 -and $n -le 360) { return '5h' }
    return ('{0}m' -f [int]$n)
}

function Get-UsageStats {
    if (-not (Test-Path -LiteralPath $SessionDir)) { return 'N/A' }
    $latest = $null
    $today = Get-Date
    foreach ($n in 0..10) {
        $day = $today.AddDays(-$n)
        $dir = Join-Path $SessionDir $day.ToString('yyyy\\MM\\dd')
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $latest = Get-ChildItem -LiteralPath $dir -Filter 'rollout-*.jsonl' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) { break }
    }
    if (-not $latest) {
        $latest = Get-ChildItem -LiteralPath $SessionDir -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if (-not $latest) { return 'N/A' }

    $lines = Get-Content -LiteralPath $latest.FullName -Tail 400 -ErrorAction SilentlyContinue
    if (-not $lines) { return 'N/A' }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ($line -notmatch 'rate_limits') { continue }
        try { $data = $line | ConvertFrom-Json } catch { continue }
        if ($data.type -ne 'event_msg' -or -not $data.payload) { continue }
        if ($data.payload.type -ne 'token_count') { continue }
        $rate = $data.payload.rate_limits
        if (-not $rate) { continue }
        $parts = @()
        foreach ($lim in @($rate.primary, $rate.secondary)) {
            if (-not $lim) { continue }
            $used = 0.0
            try { $used = [double]$lim.used_percent } catch { $used = 0.0 }
            $left = [Math]::Round([Math]::Max(0.0, 100.0 - $used), 1)
            $resetText = 'unknown'
            if ($lim.resets_at) {
                try {
                    $resetText = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$lim.resets_at)).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
                }
                catch { $resetText = 'unknown' }
            }
            $parts += '{0}: {1}% left (reset {2})' -f (Get-WindowLabel $lim.window_minutes), $left, $resetText
        }
        if ($parts.Count -gt 0) { return ($parts -join ' | ') }
    }
    return 'N/A'
}

function Find-AccountKey($Accounts, [string]$Needle) {
    if ([string]::IsNullOrWhiteSpace($Needle)) { return $null }
    $n = $Needle.ToLowerInvariant()
    foreach ($key in @($Accounts.Keys)) {
        $email = [string]$Accounts[$key].email
        if ($key.ToLowerInvariant().Contains($n) -or $email.ToLowerInvariant().Contains($n)) {
            return $key
        }
    }
    return $null
}

function Sync-CurrentAccount([switch]$Verbose) {
    $details = Get-CurrentAuthDetails
    if (-not $details -or (-not $details.Email -and -not $details.AccountId)) { return $false }
    $accounts = Get-Accounts
    $matched = $null
    foreach ($key in @($accounts.Keys)) {
        $row = $accounts[$key]
        if ($details.Email -and [string]$row.email -eq $details.Email) { $matched = $key; break }
        if ($details.AccountId -and [string]$row.account_id -eq $details.AccountId) { $matched = $key; break }
    }
    if (-not $matched) { return $false }

    $dest = Get-AccountAuthPath $matched $accounts[$matched]
    $changed = $true
    if (Test-Path -LiteralPath $dest) {
        $left = [IO.File]::ReadAllBytes($AuthFile)
        $right = [IO.File]::ReadAllBytes($dest)
        $changed = $left.Length -ne $right.Length
        if (-not $changed) {
            for ($i = 0; $i -lt $left.Length; $i++) {
                if ($left[$i] -ne $right[$i]) { $changed = $true; break }
            }
        }
    }
    if ($changed) { Copy-Atomic $AuthFile $dest }

    $row = $accounts[$matched]
    $dirty = $changed
    if ($details.Email) { $row.email = $details.Email }
    if ($details.Plan) { $row.plan = $details.Plan }
    if ($details.AccountId) { $row.account_id = $details.AccountId }
    if ($details.LastRefresh) { $row.last_refresh = $details.LastRefresh }
    if ($changed) { $row.saved_at = (Get-Date).ToString('s') }
    $accounts[$matched] = $row
    Save-Accounts $accounts
    if ($changed -and $Verbose) {
        Write-Host ("Updated saved login for account: {0}" -f $details.Email)
    }
    return $true
}

function Save-CurrentAccount {
    $details = Get-CurrentAuthDetails
    if (-not $details) {
        return @{ Ok = $false; Error = '未找到 auth.json，请先登录。' }
    }
    if (-not $details.Email) {
        return @{ Ok = $false; Error = '无法从登录信息解析邮箱。' }
    }
    $accounts = Get-Accounts
    $existed = $accounts.Contains($details.Email)
    $legacy = @()
    if ($existed) { $legacy = @($accounts[$details.Email].legacy_names) }
    $destDir = Join-Path $StoreDir (Get-SafeDirName $details.Email)
    Copy-Atomic $AuthFile (Join-Path $destDir 'auth.json')
    $accounts[$details.Email] = @{
        email        = $details.Email
        plan         = $details.Plan
        account_id   = $details.AccountId
        last_refresh = $details.LastRefresh
        saved_at     = (Get-Date).ToString('s')
        legacy_names = $legacy
    }
    Save-Accounts $accounts
    return @{ Ok = $true; Email = $details.Email; Plan = $details.Plan; Existed = $existed }
}

function Add-CurrentAccount {
    $r = Save-CurrentAccount
    if (-not $r.Ok) {
        Write-Host $r.Error -ForegroundColor Red
        return
    }
    $action = $(if ($r.Existed) { 'updated / 已更新' } else { 'created / 已创建' })
    Write-Host ("Account '{0}' {1}." -f $r.Email, $action) -ForegroundColor Green
    Write-Host ("  Plan: {0}" -f $r.Plan)
}

function Get-CodexExe {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $winget = Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft\WinGet\Links' 'codex.exe')
    if (Test-Path -LiteralPath $winget) { return $winget }
    return $null
}

function Remove-SavedAccount([string]$Key) {
    $accounts = Get-Accounts
    if (-not $accounts.Contains($Key)) {
        Write-Host ("Account '{0}' not found. / 未找到账号 '{0}'。" -f $Key) -ForegroundColor Red
        return
    }
    $names = @($Key) + @($accounts[$Key].legacy_names)
    foreach ($name in $names) {
        if (-not $name) { continue }
        $dir = Join-Path $StoreDir (Get-SafeDirName $name)
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
    $accounts.Remove($Key)
    Save-Accounts $accounts
    Write-Host ("Account '{0}' removed. / 账号 '{0}' 已删除。" -f $Key) -ForegroundColor Green
}

function Clear-CurrentAuth {
    $backup = Backup-CurrentAuth 'before-clean'
    if (Test-Path -LiteralPath $AuthFile) {
        Remove-Item -LiteralPath $AuthFile -Force
    }
    if ($backup) { Write-Host ("Previous login backed up at: {0}" -f $backup) }
    Write-Host 'Switched to Default (Clean) environment. / 已切换到默认 (干净) 环境。' -ForegroundColor Green
    Show-RestartHint
}

function Test-SavedAuthAge([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $auth = Read-JsonFile $Path
    $stamp = $null
    if ($auth -and $auth.last_refresh) {
        try { $stamp = [DateTimeOffset]::Parse([string]$auth.last_refresh) } catch { $stamp = $null }
    }
    if (-not $stamp) { $stamp = (Get-Item -LiteralPath $Path).LastWriteTimeUtc }
    $age = ([DateTimeOffset]::UtcNow - $stamp.ToUniversalTime()).TotalDays
    if ($age -gt 14) {
        Write-Host ("Saved login is {0} days old. If Codex asks to login, login once and add this account again." -f [int]$age) -ForegroundColor Yellow
    }
}

function Assert-AuthPersisted([string]$ExpectedEmail) {
    if (-not $ExpectedEmail) { return }
    Start-Sleep -Milliseconds 1500
    $current = Get-CurrentAuthDetails
    if ($current -and $current.Email -and $current.Email.ToLowerInvariant() -ne $ExpectedEmail.ToLowerInvariant()) {
        Write-Host 'Detected auth.json was overwritten by desktop cache. Close and reopen Codex desktop, then retry.' -ForegroundColor Red
    }
}

function Switch-SavedAccount([string]$Key) {
    [void](Sync-CurrentAccount -Verbose)
    $accounts = Get-Accounts
    if (-not $accounts.Contains($Key)) {
        Write-Host ("No account matched '{0}'. / 未找到匹配 '{0}' 的账号。" -f $Key) -ForegroundColor Red
        return
    }
    $src = Get-AccountAuthPath $Key $accounts[$Key]
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host ("No auth.json found for '{0}'. / 账号 '{0}' 未找到认证文件。" -f $Key) -ForegroundColor Red
        return
    }
    Test-SavedAuthAge $src
    $backup = Backup-CurrentAuth ('before-switch-{0}' -f $Key)
    Copy-Atomic $src $AuthFile
    $email = [string]$accounts[$Key].email
    Write-Host ("Successfully switched to account: {0} / 已成功切换至账号: {0}" -f $email) -ForegroundColor Green
    Write-Host ("  Plan: {0}" -f $accounts[$Key].plan)
    if ($backup) { Write-Host ("Previous login backed up at: {0}" -f $backup) }
    Show-RestartHint
    Assert-AuthPersisted $email
}

function Show-Current {
    [void](Sync-CurrentAccount)
    $details = Get-CurrentAuthDetails
    $email = $(if ($details -and $details.Email) { $details.Email } else { 'N/A' })
    $plan = $(if ($details -and $details.Plan) { $details.Plan } else { 'N/A' })
    Write-Host ''
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor Cyan
    Write-Host ('| CODEx SWITCH {0,34} |' -f ('v' + $Version)) -ForegroundColor Cyan
    Write-Host '| Windows account switcher                       |' -ForegroundColor Cyan
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('=' * 50)
    Write-Host 'Current Account / 当前账号:'
    Write-Host ' Email / 邮箱            |  Plan / 订阅 | Usage / 额度'
    Write-Host (' {0,-23} | {1,-12}| {2}' -f $email, $plan, (Get-UsageStats))
    Write-Host ('=' * 50)
}

function Show-AccountList {
    [void](Sync-CurrentAccount)
    $accounts = Get-Accounts
    if ($accounts.Count -eq 0) {
        Write-Host 'No accounts found / 未找到账号'
        return
    }
    $current = Get-CurrentAuthDetails
    $cur = $(if ($current) { $current.Email } else { '' })
    Write-Host ''
    Write-Host 'Account List' -ForegroundColor Cyan
    Write-Host ('=' * 60)
    Write-Host ('{0,-32} {1,-10}' -f 'Email/邮箱', 'Plan/订阅')
    Write-Host ('-' * 60)
    foreach ($key in @($accounts.Keys)) {
        $mark = $(if ($cur -and $key.ToLowerInvariant() -eq $cur.ToLowerInvariant()) { ' *' } else { '' })
        Write-Host ('{0,-32} {1,-10}{2}' -f $key, $accounts[$key].plan, $mark)
    }
    Write-Host ('=' * 60)
    Write-Host '* = Current account / * = 当前账号'
}

function Read-AccountPick($Accounts, [switch]$AllowClean) {
    Write-Host ''
    if ($AllowClean) { Write-Host '  0. Default (Clean) / 默认 (干净环境)' }
    $keys = @($Accounts.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host ('  {0}. {1} ({2})' -f ($i + 1), $keys[$i], $Accounts[$keys[$i]].plan)
    }
    Write-Host '  q. Cancel / 取消'
    return Read-Host 'Select index / 选择序号'
}

function Invoke-RemoveFlow {
    $accounts = Get-Accounts
    if ($accounts.Count -eq 0) {
        Write-Host 'No accounts found / 未找到账号'
        return
    }
    if ($Target) {
        $key = Find-AccountKey $accounts $Target
        if ($key) { Remove-SavedAccount $key } else { Write-Host 'Invalid choice / 无效选择' }
        return
    }
    Write-Host ''
    Write-Host 'Remove Account' -ForegroundColor Cyan
    $idx = Read-AccountPick $accounts
    if ($idx -eq 'q' -or $idx -eq 'Q') { Write-Host 'Canceled. / 已取消。'; return }
    $n = 0
    if (-not [int]::TryParse($idx, [ref]$n) -or $n -lt 1 -or $n -gt $accounts.Count) {
        Write-Host 'Invalid choice / 无效选择'
        return
    }
    Remove-SavedAccount (@($accounts.Keys)[$n - 1])
}

function Invoke-SwitchFlow {
    $accounts = Get-Accounts
    if ($Target -eq '0' -or $Target -eq '--clean') {
        [void](Sync-CurrentAccount -Verbose)
        Clear-CurrentAuth
        return
    }
    if ($Target) {
        $key = Find-AccountKey $accounts $Target
        if ($key) { Switch-SavedAccount $key } else { Write-Host 'Invalid choice / 无效选择' }
        return
    }
    Write-Host ''
    Write-Host 'Switch Account' -ForegroundColor Cyan
    $idx = Read-AccountPick $accounts -AllowClean
    if ($idx -eq 'q' -or $idx -eq 'Q') { Write-Host 'Canceled. / 已取消。'; return }
    if ($idx -eq '0') {
        [void](Sync-CurrentAccount -Verbose)
        Clear-CurrentAuth
        Write-Host 'You can now login with a new account. / 您现在可以登录新账号。'
        return
    }
    $n = 0
    if (-not [int]::TryParse($idx, [ref]$n) -or $n -lt 1 -or $n -gt $accounts.Count) {
        Write-Host 'Invalid choice / 无效选择'
        return
    }
    Switch-SavedAccount (@($accounts.Keys)[$n - 1])
}

function Invoke-SelfTest {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"email":"a@b.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}'
        )).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $jwt = 'xxx.{0}.sig' -f $payload
    $parsed = Get-AuthDetails ([pscustomobject]@{ tokens = [pscustomobject]@{ id_token = $jwt; account_id = 'acc' }; last_refresh = '2026-01-01T00:00:00Z' })
    if ($parsed.Email -ne 'a@b.com') { throw "jwt email: $($parsed.Email)" }
    if ($parsed.Plan -ne 'plus') { throw "jwt plan: $($parsed.Plan)" }
    if ((Get-WindowLabel 10080) -ne 'Weekly') { throw 'weekly label' }
    if ((Get-WindowLabel 300) -ne '5h') { throw '5h label' }
    if ((Get-WindowLabel 60) -ne '60m') { throw '60m label' }
    Write-Host 'selftest ok'
}

function Hide-ConsoleWindow {
    if (-not ('NativeConsole' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    }
    $hwnd = [NativeConsole]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) { [void][NativeConsole]::ShowWindow($hwnd, 0) }
}

function Show-Gui {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
        Start-Process $exe -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, 'gui') -WindowStyle Hidden
        return
    }
    Hide-ConsoleWindow
    . (Join-Path $PSScriptRoot 'codex-switch.gui.ps1')
}

function Show-Menu {
    while ($true) {
        Show-Current
        Write-Host ''
        Write-Host '[1] 查看账号 / List Accounts'
        Write-Host '[2] 添加账号 / Add Account'
        Write-Host '[3] 删除账号 / Remove Account'
        Write-Host '[4] 切换账号 / Switch Account'
        Write-Host '[q] 退出程序 / Exit'
        Write-Host ''
        $choice = Read-Host 'Select an option / 请选择操作'
        switch ($choice.Trim().ToLowerInvariant()) {
            '1' { Show-AccountList }
            '2' { Add-CurrentAccount }
            '3' { $script:Target = $null; Invoke-RemoveFlow }
            '4' { $script:Target = $null; Invoke-SwitchFlow }
            'q' { Write-Host 'Goodbye / 再见'; return }
            default { Write-Host 'Invalid choice / 无效选择' }
        }
    }
}

switch ($(if ($Command) { $Command.ToLowerInvariant() } else { '' })) {
    'list' { Show-AccountList }
    'add' { Add-CurrentAccount }
    'remove' { Invoke-RemoveFlow }
    'switch' { Invoke-SwitchFlow }
    'use' { Invoke-SwitchFlow }
    'current' { Show-Current }
    'selftest' { Invoke-SelfTest }
    'menu' { Show-Menu }
    'gui' { Show-Gui }
    '' { Show-Gui }
    default {
        Write-Host 'Usage: codex-switch [list|add|remove|switch|current]'
        Write-Host '       codex-switch switch <email|0>'
        Write-Host '       codex-switch remove <email>'
        exit 1
    }
}
