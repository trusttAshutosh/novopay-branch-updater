# Serves the HTML report on localhost, opens the browser, deletes the file when the tab is closed.

param(
    [Parameter(Mandatory = $true)]
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ReportPath)) {
    throw "Report not found: $ReportPath"
}

$port = 0
$listener = $null
for ($attempt = 0; $attempt -lt 25; $attempt++) {
    $candidate = Get-Random -Minimum 49152 -Maximum 65535
    $trial = [System.Net.HttpListener]::new()
    $trial.Prefixes.Add("http://127.0.0.1:$candidate/")
    try {
        $trial.Start()
        $port = $candidate
        $listener = $trial
        break
    }
    catch {
        $trial.Close()
    }
}

if (-not $listener) {
    throw 'Could not start local report server.'
}

$html = Get-Content -Path $ReportPath -Raw -Encoding UTF8
$heartbeat = @"
<script>
(function () {
  var base = 'http://127.0.0.1:$port';
  var timer = setInterval(function () {
    fetch(base + '/ping', { method: 'GET', cache: 'no-store' }).catch(function () {});
  }, 2000);
  fetch(base + '/ping', { method: 'GET', cache: 'no-store' }).catch(function () {});
  window.addEventListener('pagehide', function () {
    clearInterval(timer);
    if (navigator.sendBeacon) {
      navigator.sendBeacon(base + '/close', '');
    }
  });
})();
</script>
"@

if ($html -match '</body>') {
    $html = $html -replace '</body>', "$heartbeat`n</body>"
}
else {
    $html += $heartbeat
}

$script:lastPing = [datetime]::UtcNow
$script:forceClose = $false
$script:reportHtml = $html

function Send-TextResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$Text
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/plain; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Handle-ReportRequest {
    param([System.Net.HttpListenerContext]$Context)

    $path = $Context.Request.Url.AbsolutePath.ToLowerInvariant()
    switch ($path) {
        '/ping' {
            $script:lastPing = [datetime]::UtcNow
            Send-TextResponse -Context $Context -Text 'ok'
        }
        '/close' {
            $script:forceClose = $true
            Send-TextResponse -Context $Context -Text 'ok'
        }
        default {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:reportHtml)
            $Context.Response.StatusCode = 200
            $Context.Response.ContentType = 'text/html; charset=utf-8'
            $Context.Response.ContentLength64 = $bytes.Length
            $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $Context.Response.OutputStream.Close()
        }
    }
}

$callback = {
    param($Result)
    $httpListener = $Result.AsyncState
    if (-not $httpListener.IsListening) {
        return
    }

    try {
        $context = $httpListener.EndGetContext($Result)
        Handle-ReportRequest -Context $context
    }
    catch {
        # Listener stopped.
    }

    if ($httpListener.IsListening) {
        $httpListener.BeginGetContext($callback, $httpListener) | Out-Null
    }
}

$listener.BeginGetContext($callback, $listener) | Out-Null
Start-Process "http://127.0.0.1:$port/"

while (-not $script:forceClose) {
    Start-Sleep -Seconds 2
    $idleSeconds = ([datetime]::UtcNow - $script:lastPing).TotalSeconds
    if ($idleSeconds -ge 8) {
        break
    }
}

$listener.Stop()
$listener.Close()

if (Test-Path $ReportPath) {
    Remove-Item -Path $ReportPath -Force
}
