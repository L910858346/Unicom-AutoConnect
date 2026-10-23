#Requires -Version 5.1
<#
    Test-CampusNet.ps1 —— 离线自检
    用本地临时 TCP 服务器模拟“门户劫持”，验证联网探测、门户识别与后台表单认证逻辑。
    不联网、不改系统、不碰无线。
    用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CampusNet.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CampusNet.psm1') -Force

$CRLF = [string]([char]13) + [string]([char]10)
$passed = 0
$failed = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host ("  [FAIL] {0}  期望=[{1}]  实际=[{2}]" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:failed++
    }
}

function New-Response {
    param([int]$Status, [string]$Reason, [string]$Body, [string]$ContentType, [string]$Location)
    $head = "HTTP/1.1 $Status $Reason" + $CRLF
    if ($Location) { $head += "Location: $Location" + $CRLF }
    $head += "Content-Type: $ContentType" + $CRLF
    $head += "Content-Length: " + ([Text.Encoding]::UTF8.GetByteCount($Body)) + $CRLF
    $head += "Connection: close" + $CRLF + $CRLF
    return $head + $Body
}

# ---------- 启动本地模拟门户 ----------
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()

$postFile = Join-Path $env:TEMP ("unicom-mock-post-{0}.txt" -f $PID)
if (Test-Path -LiteralPath $postFile) { Remove-Item -LiteralPath $postFile -Force }

$job = Start-Job -ArgumentList $port, $postFile -ScriptBlock {
    param($Port, $PostFile)
    $crlf = [string]([char]13) + [string]([char]10)
    function Respond {
        param([string]$Status, [string]$Reason, [string]$Body, [string]$Type, [string]$Location)
        $head = "HTTP/1.1 $Status $Reason" + $crlf
        if ($Location) { $head += "Location: $Location" + $crlf }
        $head += "Content-Type: $Type" + $crlf
        $head += "Content-Length: " + ([Text.Encoding]::UTF8.GetByteCount($Body)) + $crlf
        $head += "Connection: close" + $crlf + $crlf
        return $head + $Body
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $buffer = New-Object byte[] 4096
            $ms = New-Object System.IO.MemoryStream
            # 一直读到「请求头收全 且 请求体收满」为止。
            # 注意两个坑：(1) 请求头可能被 TCP 分段，第一次 Read 未必拿得到空行；
            #             (2) POST 带 Expect: 100-continue 时，body 会在头之后约 350ms 才发出。
            $request = ''
            $headerEnd = -1
            $readDeadline = (Get-Date).AddSeconds(6)
            while ((Get-Date) -lt $readDeadline) {
                if ($stream.DataAvailable -or $ms.Length -eq 0) {
                    $read = $stream.Read($buffer, 0, 4096)
                    if ($read -le 0) { break }
                    $ms.Write($buffer, 0, $read)
                }
                $request = [Text.Encoding]::ASCII.GetString($ms.ToArray())
                $headerEnd = $request.IndexOf($crlf + $crlf)
                if ($headerEnd -ge 0) {
                    $contentLength = 0
                    $clm = [regex]::Match($request, '(?i)Content-Length:\s*(\d+)')
                    if ($clm.Success) { $contentLength = [int]$clm.Groups[1].Value }
                    if (($request.Length - ($headerEnd + 4)) -ge $contentLength) { break }
                }
                if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 50 }
            }
            $parts = $request -split ' '
            $path = '/'
            if ($parts.Count -gt 1) { $path = $parts[1] }
            $reqBody = ''
            if ($headerEnd -ge 0 -and $request.Length -gt ($headerEnd + 4)) { $reqBody = $request.Substring($headerEnd + 4) }

            if ($path -like '*hijack-refresh*') {
                $body = '<html><head><meta http-equiv="refresh" content="0;url=http://192.0.2.10:8080/portal/login"></head><body>portal</body></html>'
                $text = Respond '200' 'OK' $body 'text/html' ''
            } elseif ($path -like '*hijack-form*') {
                $body = '<html><body><form action="/portal/login.php" method="post"><input name="username"></form></body></html>'
                $text = Respond '200' 'OK' $body 'text/html' ''
            } elseif ($path -like '*redirect*') {
                $text = Respond '302' 'Found' '' 'text/plain' 'http://192.0.2.10:8080/portal/login'
            } elseif ($path -like '*frameset*') {
                # 复刻常见的框架式运营商门户：外层是 frameset，noframes 里只有一个没有密码框的兜底表单
                $body = '<html><head><title>ChinaUnicom</title></head><frameset rows="0,*"><frame name="hiddenFrame" src="blank.html"><frame name="mainFrame" src="/style/default_lan/index.jsp"></frameset><noframes><body><form name="loginform" action="/unicomclient.jsp" method="post"><input type="hidden" name="wlanacname" value="TEST-AC-01"><input type="hidden" name="wlanuserip" value="198.51.100.23"><input type="hidden" name="actiontype" value="LOGIN"></form></body></noframes></html>'
                $text = Respond '200' 'OK' $body 'text/html' ''
            } elseif ($path -like '*unicomclient*' -or $path -like '*index.jsp*') {
                # 真正带账号密码的子框架
                $body = '<html><body><form name="f" action="unicomclient.jsp" method="post"><input type="hidden" name="token" value="TOKEN123"><input type="hidden" name="wlanacname" value="TEST-AC-01"><input type="hidden" name="wlanuserip" value="198.51.100.23"><input type="text" name="username" value=""><input type="password" name="password" value=""><input type="submit" name="submit" value="login"></form></body></html>'
                $text = Respond '200' 'OK' $body 'text/html' ''
            } elseif ($path -like '*.js*') {
                # 复刻真实门户：真实提交地址藏在 JS 里，表单 action 是空的
                $body = 'function doLogin(){ if(document.forms[0].username.value==""){return false;} document.forms[0].action = "/portalLogin"; return true; }'
                $text = Respond '200' 'OK' $body 'application/javascript' ''
            } elseif ($path -like '*InterFace.do*') {
                # 锐捷 ePortal AJAX 登录接口（InterFace.do?method=login）：记录 POST 体，返回标准 JSON
                if ($PostFile) { [IO.File]::WriteAllText($PostFile, $reqBody, (New-Object Text.UTF8Encoding $false)) }
                $text = Respond '200' 'OK' '{"result":"success","message":"","userIndex":"idx-mock-001","keepaliveInterval":60}' 'application/json' ''
            } elseif ($path -like '*portalLogin*') {
                # 记录收到的登录表单，供测试断言
                if ($PostFile) { [IO.File]::WriteAllText($PostFile, $reqBody, (New-Object Text.UTF8Encoding $false)) }
                $text = Respond '200' 'OK' 'login ok' 'text/html' ''
            } elseif ($path -like '*gateway*') {
                $text = Respond '204' 'No Content' '' 'text/plain' ''
            } else {
                $text = Respond '200' 'OK' 'Microsoft Connect Test' 'text/plain' ''
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch { }
        $client.Close()
    }
    $listener.Stop()
}

# 等待服务就绪
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port)
        $c.Close()
        $ready = $true
        break
    } catch { Start-Sleep -Milliseconds 250 }
}

Write-Host ''
Write-Host ("===== CampusNet 离线自检（模拟服务端口 {0}）=====" -f $port) -ForegroundColor Cyan
if (-not $ready) {
    Write-Host '  [FAIL] 本地模拟服务未能启动' -ForegroundColor Red
    Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    exit 1
}

$base = "http://127.0.0.1:$port"
$config = Get-CampusConfig -Path (Join-Path $root 'config\config.example.json')

Write-Host '1) 正常联网（探测内容匹配）'
$config.probes = @(@{ url = "$base/connecttest.txt"; expect = 'Microsoft Connect Test'; expectStatus = 0 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal 'Online 应为 true' $true $r.Online

Write-Host '2) 门户用 meta refresh 劫持'
$config.probes = @(@{ url = "$base/hijack-refresh"; expect = 'Microsoft Connect Test'; expectStatus = 0 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal 'Online 应为 false' $false $r.Online
Assert-Equal '门户地址（meta refresh）' 'http://192.0.2.10:8080/portal/login' $r.PortalUrl

Write-Host '3) 门户用表单页劫持（相对 action 需补全）'
$config.probes = @(@{ url = "$base/hijack-form"; expect = 'Microsoft Connect Test'; expectStatus = 0 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal '门户地址（form action 相对路径）' "$base/portal/login.php" $r.PortalUrl

Write-Host '4) 门户用 302 重定向'
$config.probes = @(@{ url = "$base/redirect"; expect = ''; expectStatus = 204 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal 'Online 应为 false' $false $r.Online
Assert-Equal '门户地址（Location）' 'http://192.0.2.10:8080/portal/login' $r.PortalUrl

Write-Host '5) 期望状态码 204'
$config.probes = @(@{ url = "$base/gateway"; expect = ''; expectStatus = 204 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal 'Online 应为 true' $true $r.Online

Write-Host '6) 请求失败（端口不通）应判为未联网'
$config.probes = @(@{ url = 'http://127.0.0.1:1/nothing'; expect = 'x'; expectStatus = 0 })
$r = Invoke-CampusConnectivityCheck -Config $config
Assert-Equal 'Online 应为 false' $false $r.Online

Write-Host '7) 配置合并与项目默认值'
$config2 = Get-CampusConfig -Path (Join-Path $root 'config\config.example.json')
Assert-Equal 'ssid 第一项' 'YOUR_CAMPUS_SSID' $config2.ssid[0]
Assert-Equal 'profileName 自动补全' 'YOUR_CAMPUS_SSID' $config2.profileName
Assert-Equal 'browser.enabled 默认 false' $false $config2.browser.enabled
Assert-Equal 'autoLogin.enabled 默认 true' $true $config2.autoLogin.enabled
Assert-Equal 'autoLogin.mode 默认 eportal' 'eportal' $config2.autoLogin.mode

$configDefault = Get-CampusConfig -Path (Join-Path $root 'config\__not_exists__.json')
Assert-Equal '内置默认 ssid' 'YOUR_CAMPUS_SSID' $configDefault.ssid[0]
Assert-Equal '内置默认关闭浏览器' $false $configDefault.browser.enabled
Assert-Equal '内置默认启用后台认证' $true $configDefault.autoLogin.enabled

# config/config.json 是本地私有文件，可能已被用户填成实际 SSID / 账号，测试不依赖它的具体值。

Write-Host '8) 门户表单解析（抓包助手）：识别提交地址与字段'
$sampleHtml = @'
<html><body>
<form name="loginForm" action="/portal/login.do" method="post">
  <input type="hidden" name="nasip" value="192.0.2.3">
  <input type="text" name="wlanuserip" value="192.0.2.40">
  <input type="text" name="username" value="">
  <input type="password" name="password" value="">
  <select name="isp"><option value="unicom">中国联通</option><option value="telecom">中国电信</option></select>
  <input type="checkbox" name="agree" value="1">
  <input type="submit" value="登录">
</form>
</body></html>
'@
$form = Get-CampusPortalForm -Html $sampleHtml -Base 'http://192.0.2.10/portal/index.html'
Assert-Equal '提交地址（相对路径补全）' 'http://192.0.2.10/portal/login.do' $form.Action
Assert-Equal '提交方法' 'POST' $form.Method
Assert-Equal '账号字段' 'username' $form.UsernameField
Assert-Equal '密码字段' 'password' $form.PasswordField
Assert-Equal '具名字段总数（5 个有 name 的 input + 1 个 select；无 name 的 submit 被忽略）' 6 $form.Fields.Count
Assert-Equal 'wlanuserip 这类基础设施字段不会抢走账号位' 'username' $form.UsernameField
Assert-Equal 'blocked：wlanuserip 仍作为普通字段保留' 'wlanuserip' (($form.Fields | Where-Object { $_.name -eq 'wlanuserip' }).name)
$ispField = $form.Fields | Where-Object { $_.name -eq 'isp' }
Assert-Equal 'select 默认值取第一个 option' 'unicom' $ispField.value
$hidden = $form.Fields | Where-Object { $_.name -eq 'nasip' }
Assert-Equal 'hidden 字段保留原值' '192.0.2.3' $hidden.value

Write-Host '9) 门户表单解析：只有账号框、没有密码框时不误判'
$html2 = '<html><body><form action="http://x/y"><input type="text" name="account"><input type="submit"></form></body></html>'
$form2 = Get-CampusPortalForm -Html $html2 -Base 'http://x/'
Assert-Equal '账号字段' 'account' $form2.UsernameField
Assert-Equal '密码字段为空' '' $form2.PasswordField

Write-Host '10) 框架式门户（联通校园网常见结构）：自动跟进子框架找到密码框'
$config.probes = @(@{ url = "$base/connecttest.txt"; expect = 'Microsoft Connect Test'; expectStatus = 0 })
$snap = Get-CampusPortalSnapshot -Config $config -Url "$base/frameset.html"
Assert-Equal '最终落在子框架（Depth=1）' 1 $snap.Depth
Assert-Equal '保留了最初的门户地址' "$base/frameset.html" $snap.PortalUrl
Assert-Equal '密码字段来自子框架' 'password' $snap.Form.PasswordField
Assert-Equal '账号字段来自子框架' 'username' $snap.Form.UsernameField
Assert-Equal '子框架里的相对 action 按 RFC 补全到子框架所在目录' "$base/style/default_lan/unicomclient.jsp" $snap.Form.Action

Write-Host '11) 门户表单模式后台认证（框架页 + 隐藏令牌 + 自动识别字段）'
$config.autoLogin = @{
    enabled        = $true
    mode           = 'portal-form'
    portalUrl      = "$base/frameset.html"
    submitUrl      = '/portalLogin'
    username       = 'alice'
    password       = 'secret'
    usernameField  = ''
    passwordField  = ''
    extraFields    = @{ serviceType = '301' }
    useReferer     = $true
    method         = 'POST'
    contentType    = 'application/x-www-form-urlencoded'
    timeoutSeconds = 10
}
$ok = Invoke-CampusAutoLogin -Config $config
Assert-Equal '登录调用返回 true' $true $ok
Start-Sleep -Milliseconds 500
$posted = ''
if (Test-Path -LiteralPath $postFile) { $posted = Get-Content -LiteralPath $postFile -Raw }
Write-Host ("  [debug] mock 收到: " + $posted) -ForegroundColor DarkGray
Assert-Equal '确实收到了 POST 请求体' 'true' ([bool]$posted)
Assert-Equal '带上了账号' 'true' ([bool]($posted -match 'username=alice'))
Assert-Equal '带上了密码' 'true' ([bool]($posted -match 'password=secret'))
Assert-Equal '带上了子框架里的隐藏令牌 token' 'true' ([bool]($posted -match 'token=TOKEN123'))
Assert-Equal '带上了子框架里的网络参数 wlanacname' 'true' ([bool]($posted -match 'wlanacname=TEST-AC-01'))
Assert-Equal '带上了 extraFields' 'true' ([bool]($posted -match 'serviceType=301'))

Write-Host '12) autoLogin 关闭时不动作 / portal-form 缺账号密码时安全退出'
$config.autoLogin = @{ enabled = $false; mode = 'portal-form'; username = 'a'; password = 'b' }
Assert-Equal 'enabled=false 时返回 false' $false (Invoke-CampusAutoLogin -Config $config)
$config.autoLogin = @{ enabled = $true; mode = 'portal-form'; portalUrl = "$base/frameset.html"; username = ''; password = ''; submitUrl = '/portalLogin'; method = 'POST'; contentType = 'application/x-www-form-urlencoded'; timeoutSeconds = 5; extraFields = @{}; extraHeaders = @{} }
Assert-Equal '缺账号密码时安全返回 false（不发起请求）' $false (Invoke-CampusAutoLogin -Config $config)

Write-Host '13) 从 JS 里自动发现真实提交地址（表单 action 为空的门户）'
$pageHtml = '<html><head><script language="javascript" src="/js/main_cu.js"></script></head><body><form action="" method="post"><input type="password" name="password"></form></body></html>'
$found = Get-CampusFormActionFromScripts -Html $pageHtml -Base "$base/style/default_lan/index.jsp"
Assert-Equal '扫 JS 找到 /portalLogin 并补全为绝对地址' "$base/portalLogin" $found
Assert-Equal '页面里没有 script src 时返回空' '' (Get-CampusFormActionFromScripts -Html '<html></html>' -Base $base)

Write-Host '14) ePortal 模式自动登录（锐捷 InterFace.do?method=login，双重 URL 编码）'
if (Test-Path -LiteralPath $postFile) { Remove-Item -LiteralPath $postFile -Force }
$config.autoLogin = @{
    enabled        = $true
    mode           = 'eportal'
    eportalService = ''
    portalUrl      = "$base/eportal/index.jsp?wlanuserip=192.0.2.4&wlanacname=ac01&mac=001122334455"
    username       = 'testuser'
    password       = 'testpass'
    method         = 'POST'
    contentType    = 'application/x-www-form-urlencoded'
    timeoutSeconds = 10
    extraFields    = @{}
    extraHeaders   = @{}
    useReferer     = $true
}
$ok = Invoke-CampusAutoLogin -Config $config
Assert-Equal 'eportal 登录调用返回 true' $true $ok
Start-Sleep -Milliseconds 500
$eposted = ''
if (Test-Path -LiteralPath $postFile) { $eposted = Get-Content -LiteralPath $postFile -Raw }
Write-Host ("  [debug] eportal mock 收到: " + $eposted) -ForegroundColor DarkGray
Assert-Equal 'POST 到 InterFace.do 且带上了 userId' 'true' ([bool]($eposted -match 'userId=testuser'))
Assert-Equal '带上了 password' 'true' ([bool]($eposted -match 'password=testpass'))
Assert-Equal 'queryString 被双重编码（= 变成 %253D）' 'true' ([bool]($eposted -match 'queryString=wlanuserip%253D192\.0\.2\.4'))
Assert-Equal 'queryString 参数间的 & 被双重编码（%2526）' 'true' ([bool]($eposted -match '%2526wlanacname'))
Assert-Equal 'passwordEncrypt=false' 'true' ([bool]($eposted -match 'passwordEncrypt=false'))
Assert-Equal 'validcode 留空提交' 'true' ([bool]($eposted -match 'validcode=&'))

Write-Host '15) ePortal 门户地址缺少 queryString 时安全退出（不发起登录）'
$config.autoLogin.portalUrl = "$base/connecttest.txt"
Assert-Equal '无 queryString 返回 false' $false (Invoke-CampusAutoLogin -Config $config)
$config.autoLogin.username = ''
$config.autoLogin.password = ''
$config.autoLogin.portalUrl = "$base/eportal/index.jsp?wlanuserip=192.0.2.4"
Assert-Equal '缺账号密码返回 false' $false (Invoke-CampusAutoLogin -Config $config)

Write-Host '16) 表单 action 查询串里的 method= 不污染提交方法识别（ePortal 回归）'
$html3 = '<html><body><form id="haiJunForm" action="validateHaijun.do?method=manage" method="post"><input type="text" name="username"><input type="password" name="pwd"></form></body></html>'
$form3 = Get-CampusPortalForm -Html $html3 -Base 'http://portal.example.test/eportal/index.jsp'
Assert-Equal '提交方法仍为 POST（不被 ?method=manage 污染）' 'POST' $form3.Method
Assert-Equal 'action 原样保留查询串' 'http://portal.example.test/eportal/validateHaijun.do?method=manage' $form3.Action

Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("===== 通过 {0} 项，失败 {1} 项 =====" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { exit 1 }
exit 0
