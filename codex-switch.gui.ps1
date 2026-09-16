#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'Codex Switch') | Out-Null
    })

$script:LoginProc = $null
$script:LoginWatch = $null
$script:UiBusy = $false

function New-UiButton([string]$Text, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [int]$W = 108, [int]$H = 32) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $W
    $b.Height = $H
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    return $b
}

function Set-Status([string]$Text) {
    $script:StatusLabel.Text = $Text
}

function Set-Busy([bool]$Busy) {
    $script:UiBusy = $Busy
    foreach ($c in @($script:BtnLogin, $script:BtnSave, $script:BtnClear, $script:ListHost)) {
        if ($c) { $c.Enabled = -not $Busy }
    }
}

function Refresh-Ui {
    try {
        [void](Sync-CurrentAccount)
    }
    catch {
        Set-Status $_.Exception.Message
    }
    $cur = Get-CurrentAuthDetails
    $email = if ($cur -and $cur.Email) { $cur.Email } else { '未登录' }
    $plan = if ($cur -and $cur.Plan) { $cur.Plan } else { '-' }
    $script:LblEmail.Text = $email
    $script:LblMeta.Text = '{0}    {1}' -f $plan, (Get-UsageStats)
    $script:CurrentEmail = $(if ($cur) { $cur.Email } else { '' })

    $script:ListHost.Controls.Clear()
    try {
        $accounts = Get-Accounts
    }
    catch {
        Set-Status $_.Exception.Message
        return
    }
    $width = [Math]::Max(240, $script:ListHost.ClientSize.Width - 36)
    $y = 8
    foreach ($key in @($accounts.Keys)) {
        try {
            $row = New-AccountRow $key $accounts[$key] $width
            $row.Location = New-Object System.Drawing.Point(16, $y)
            $script:ListHost.Controls.Add($row)
            $y += $row.Height + 8
        }
        catch {
            Set-Status $_.Exception.Message
        }
    }
    if ($accounts.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = '还没有保存的账号。点「登录新账号」，浏览器登录后会自动存下来。'
        $empty.ForeColor = [System.Drawing.Color]::FromArgb(100, 110, 125)
        $empty.AutoSize = $true
        $empty.MaximumSize = New-Object System.Drawing.Size($width, 0)
        $empty.Location = New-Object System.Drawing.Point(16, 12)
        $script:ListHost.Controls.Add($empty)
    }
    else {
        Set-Status ('已保存 {0} 个账号，点「切换」即可换号。' -f $accounts.Count)
    }
}

function New-AccountRow([string]$Key, $Data, [int]$Width) {
    $isCurrent = $script:CurrentEmail -and $Key.Equals($script:CurrentEmail, [StringComparison]::OrdinalIgnoreCase)
    $row = New-Object System.Windows.Forms.Panel
    $row.Width = $Width
    $row.Height = 64
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $row.BackColor = [System.Drawing.Color]::White

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Width = 4
    $bar.Dock = 'Left'
    $bar.BackColor = if ($isCurrent) { [System.Drawing.Color]::FromArgb(37, 99, 235) } else { [System.Drawing.Color]::FromArgb(226, 232, 240) }
    $row.Controls.Add($bar)

    $mail = New-Object System.Windows.Forms.Label
    $mail.Text = $Key
    $mail.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $mail.Location = New-Object System.Drawing.Point(16, 10)
    $mail.AutoSize = $true
    $row.Controls.Add($mail)

    $meta = New-Object System.Windows.Forms.Label
    $meta.Text = if ($isCurrent) { '{0}  ·  当前使用中' -f $Data.plan } else { [string]$Data.plan }
    $meta.ForeColor = [System.Drawing.Color]::FromArgb(100, 110, 125)
    $meta.Location = New-Object System.Drawing.Point(16, 34)
    $meta.AutoSize = $true
    $row.Controls.Add($meta)

    $btnDel = New-UiButton '删除' ([System.Drawing.Color]::FromArgb(254, 226, 226)) ([System.Drawing.Color]::FromArgb(185, 28, 28)) 72
    $btnDel.Anchor = 'Top,Right'
    $btnDel.Location = New-Object System.Drawing.Point(($Width - 88), 16)
    $btnDel.Tag = $Key
    $btnDel.Add_Click({
        $k = $this.Tag
        if ([System.Windows.Forms.MessageBox]::Show("删除保存的账号 $k ？`n不会退出当前 Codex 登录。", '删除账号', 'YesNo', 'Warning') -ne 'Yes') { return }
        Remove-SavedAccount $k
        Refresh-Ui
        Set-Status "已删除 $k"
    })
    $row.Controls.Add($btnDel)

    if (-not $isCurrent) {
        $btnSw = New-UiButton '切换' ([System.Drawing.Color]::FromArgb(37, 99, 235)) ([System.Drawing.Color]::White) 72
        $btnSw.Anchor = 'Top,Right'
        $btnSw.Location = New-Object System.Drawing.Point(($Width - 168), 16)
        $btnSw.Tag = $Key
        $btnSw.Add_Click({
            $k = $this.Tag
            Switch-SavedAccount $k
            Refresh-Ui
            Set-Status "已切换到 $k"
            [System.Windows.Forms.MessageBox]::Show("已切换到 $k`n`n请完全关闭并重新打开 Codex / ChatGPT，让账号生效。", '切换完成') | Out-Null
        })
        $row.Controls.Add($btnSw)
    }

    return $row
}

function Stop-LoginWatch {
    if ($script:LoginWatch) { $script:LoginWatch.Stop(); $script:LoginWatch.Dispose(); $script:LoginWatch = $null }
    $script:LoginProc = $null
    Set-Busy $false
}

function Complete-Login {
    $r = Save-CurrentAccount
    Stop-LoginWatch
    Refresh-Ui
    if ($r.Ok) {
        Set-Status ("已保存账号 {0}" -f $r.Email)
        [System.Windows.Forms.MessageBox]::Show(("登录成功，已保存：{0}`n订阅：{1}`n`n以后在列表里点「切换」即可。" -f $r.Email, $r.Plan), '登录成功') | Out-Null
    }
    else {
        Set-Status $r.Error
        [System.Windows.Forms.MessageBox]::Show($r.Error, '保存失败') | Out-Null
    }
}

function Start-BrowserLogin {
    $codex = Get-CodexExe
    if (-not $codex) {
        [System.Windows.Forms.MessageBox]::Show('未找到 codex.exe。请先安装 Codex CLI。', '无法登录') | Out-Null
        return
    }
    $msg = "将打开浏览器登录 ChatGPT / Codex。`n`n当前账号会先自动保存。`n登录成功后，新账号会存到本地，点「切换」就能换号。"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '登录新账号', 'OKCancel', 'Information') -ne 'OK') { return }

    $cur = Get-CurrentAuthDetails
    if ($cur -and $cur.Email) { [void](Save-CurrentAccount) }
    [void](Backup-CurrentAuth 'before-login')
    if (Test-Path -LiteralPath $AuthFile) { Remove-Item -LiteralPath $AuthFile -Force }

    Set-Busy $true
    Set-Status '正在打开浏览器，请登录…'
    Refresh-Ui

    $script:LoginStarted = Get-Date
    $script:LoginProc = Start-Process -FilePath $codex -ArgumentList 'login' -PassThru -WindowStyle Minimized

    $script:LoginWatch = New-Object System.Windows.Forms.Timer
    $script:LoginWatch.Interval = 1000
    $script:LoginWatch.Add_Tick({
        $authReady = $false
        if (Test-Path -LiteralPath $AuthFile) {
            $details = Get-CurrentAuthDetails
            $fresh = (Get-Item -LiteralPath $AuthFile).LastWriteTime -ge $script:LoginStarted.AddSeconds(-2)
            if ($details -and $details.Email -and $fresh) { $authReady = $true }
        }
        $exited = $script:LoginProc -and $script:LoginProc.HasExited
        if ($authReady) {
            Complete-Login
            return
        }
        if ($exited -and -not (Test-Path -LiteralPath $AuthFile)) {
            if (((Get-Date) - $script:LoginStarted).TotalSeconds -gt 4) {
                Stop-LoginWatch
                Set-Status '登录没有完成（未写入账号文件）'
                [System.Windows.Forms.MessageBox]::Show('登录未完成。可以再点一次「登录新账号」。', '登录取消') | Out-Null
            }
            return
        }
        if (((Get-Date) - $script:LoginStarted).TotalMinutes -gt 10) {
            Stop-LoginWatch
            Set-Status '登录超时'
            [System.Windows.Forms.MessageBox]::Show('等待登录超时。请重试。', '超时') | Out-Null
        }
    })
    $script:LoginWatch.Start()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Switch'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(720, 620)
$form.MinimumSize = New-Object System.Drawing.Size(640, 520)
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 245, 247)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Add_FormClosing({ Stop-LoginWatch })

$header = New-Object System.Windows.Forms.Panel
$header.Height = 200
$header.Dock = 'Top'
$header.BackColor = [System.Drawing.Color]::White

$lblNow = New-Object System.Windows.Forms.Label
$lblNow.Text = '当前账号'
$lblNow.ForeColor = [System.Drawing.Color]::FromArgb(100, 110, 125)
$lblNow.AutoSize = $true
$lblNow.Location = New-Object System.Drawing.Point(20, 14)
$header.Controls.Add($lblNow)

$script:LblEmail = New-Object System.Windows.Forms.Label
$script:LblEmail.Text = '…'
$script:LblEmail.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$script:LblEmail.AutoSize = $true
$script:LblEmail.Location = New-Object System.Drawing.Point(20, 36)
$header.Controls.Add($script:LblEmail)

$script:LblMeta = New-Object System.Windows.Forms.Label
$script:LblMeta.Text = ''
$script:LblMeta.ForeColor = [System.Drawing.Color]::FromArgb(100, 110, 125)
$script:LblMeta.AutoSize = $true
$script:LblMeta.Location = New-Object System.Drawing.Point(20, 68)
$header.Controls.Add($script:LblMeta)

$script:BtnLogin = New-UiButton '登录新账号' ([System.Drawing.Color]::FromArgb(37, 99, 235)) ([System.Drawing.Color]::White) 120
$script:BtnLogin.Location = New-Object System.Drawing.Point(20, 104)
$script:BtnLogin.Add_Click({ Start-BrowserLogin })
$header.Controls.Add($script:BtnLogin)

$script:BtnSave = New-UiButton '保存当前登录' ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(30, 41, 59)) 120
$script:BtnSave.Location = New-Object System.Drawing.Point(150, 104)
$script:BtnSave.Add_Click({
    $r = Save-CurrentAccount
    Refresh-Ui
    if ($r.Ok) { Set-Status ("已保存 {0}" -f $r.Email) }
    else { Set-Status $r.Error; [System.Windows.Forms.MessageBox]::Show($r.Error, '保存失败') | Out-Null }
})
$header.Controls.Add($script:BtnSave)

$script:BtnClear = New-UiButton '清空登录' ([System.Drawing.Color]::FromArgb(254, 243, 226)) ([System.Drawing.Color]::FromArgb(154, 52, 18)) 96
$script:BtnClear.Location = New-Object System.Drawing.Point(280, 104)
$script:BtnClear.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('清空当前登录？会先备份。随后可再登录新账号。', '清空登录', 'YesNo', 'Warning') -ne 'Yes') { return }
    $cur = Get-CurrentAuthDetails
    if ($cur -and $cur.Email) { [void](Save-CurrentAccount) }
    Clear-CurrentAuth
    Refresh-Ui
    Set-Status '已清空当前登录'
})
$header.Controls.Add($script:BtnClear)

$head = New-Object System.Windows.Forms.Label
$head.Text = '已保存的账号'
$head.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$head.AutoSize = $true
$head.Location = New-Object System.Drawing.Point(20, 154)
$header.Controls.Add($head)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Dock = 'Bottom'
$script:StatusLabel.Height = 28
$script:StatusLabel.Padding = New-Object System.Windows.Forms.Padding(16, 6, 16, 4)
$script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$script:StatusLabel.Text = '登录后自动保存账号信息，点切换即可换号。'

$script:ListHost = New-Object System.Windows.Forms.Panel
$script:ListHost.Dock = 'Fill'
$script:ListHost.AutoScroll = $true
$script:ListHost.BackColor = [System.Drawing.Color]::FromArgb(244, 245, 247)

$form.Controls.Add($script:ListHost)
$form.Controls.Add($script:StatusLabel)
$form.Controls.Add($header)

$form.Add_Shown({
    $form.BringToFront()
    Refresh-Ui
})

[void]$form.ShowDialog()
