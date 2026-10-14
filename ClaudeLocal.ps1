<#
.SYNOPSIS
    Run Claude Code against LM Studio models (see ClaudeLocalSetup.md).

.DESCRIPTION
    Dot-source this file (e.g. from $PROFILE) to get:

      Start-ClaudeLocal / claude-local   Check LM Studio, sync the model list into the
                                         settings file, then launch claude --settings.
      Update-ClaudeLocalSettings         Sync LM Studio's models into the settings file only.
      Set-ClaudeLocalServer              Point the settings file at another machine running LM Studio.
      Set-ClaudeLocalApiKey              Save the API key LM Studio requires (Require Authentication).
      Test-LmChatTemplate                Check each model's chat template for the rules that
                                         break Claude Code (static scan, or -Live requests).
      Test-LmStudioServer                $true if the LM Studio server answers.
      Start-LmStudioServer               Start the server with `lms` if it is not running.
      Get-LmStudioModel                  List the chat models the server exposes.

    Profile usage:
      . 'C:\Files\ClaudeLocal\ClaudeLocal.ps1'
#>

# CLAUDELOCAL_BASEURL / CLAUDELOCAL_TOKEN supply the server and API key only until a settings
# file exists; the settings file takes over after that (see Get-LmSettingsConnection below).
$script:LmDefaultBaseUrl  = if ($env:CLAUDELOCAL_BASEURL) { $env:CLAUDELOCAL_BASEURL.TrimEnd('/') } else { 'http://localhost:1234' }
$script:LmAuthToken       = if ($env:CLAUDELOCAL_TOKEN) { $env:CLAUDELOCAL_TOKEN } else { 'lmstudio' }
$script:LmDefaultSettings = Join-Path $env:USERPROFILE '.claude\lmstudio.settings.json'
$script:LmHome            = Join-Path $env:USERPROFILE '.lmstudio'
$script:LmLogPath         = Join-Path $env:USERPROFILE '.claude\logs\ClaudeLocal.log'
$script:LmLogMaxBytes     = 2MB

# Template rules that Claude Code's request layout trips over (see "Fixing chat template errors").
$script:LmBadTemplateRules = @(
    @{ Pattern = 'System message must be at the beginning'; Why = 'Claude Code can send system content after the first message' }
    @{ Pattern = 'System role not supported';               Why = 'Claude Code always sends a system prompt' }
    @{ Pattern = 'must alternate';                          Why = 'Claude Code can send two user turns in a row after tool results' }
)

function Write-LmLog {
    <#
    .SYNOPSIS
        Append one CMTrace-format line to $script:LmLogPath. Only called when a file is changed.
        Severity: 1 = info, 2 = warning, 3 = error. A log over $script:LmLogMaxBytes is
        rolled to .lo_ (the ConfigMgr convention, which CMTrace opens alongside the .log).
    #>
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet(1, 2, 3)] [int]$Severity = 1,
        [string]$Component = 'ClaudeLocal'
    )

    $dir = Split-Path $script:LmLogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $script:LmLogPath) -and (Get-Item $script:LmLogPath).Length -gt $script:LmLogMaxBytes) {
        Move-Item $script:LmLogPath ([IO.Path]::ChangeExtension($script:LmLogPath, '.lo_')) -Force
    }

    $now    = Get-Date
    # CMTrace wants the UTC bias in minutes with the sign flipped (UTC-4 -> +240).
    $bias   = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $caller = (Get-PSCallStack)[1]
    $file   = if ($caller.ScriptName) { '{0}:{1}' -f (Split-Path $caller.ScriptName -Leaf), $caller.ScriptLineNumber } else { '' }
    $line   = '<![LOG[{0}]LOG]!><time="{1:HH:mm:ss.fff}{2:+0;-0}" date="{1:MM-dd-yyyy}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f `
        $Message, $now, $bias, $Component, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $Severity, $PID, $file

    [IO.File]::AppendAllText($script:LmLogPath, $line + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Get-LmsExe {
    $cmd = Get-Command lms -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $script:LmHome 'bin\lms.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Test-LmLocalUrl {
    # The lms CLI and ~\.lmstudio files only describe this machine's LM Studio.
    param([string]$BaseUrl = $script:LmDefaultBaseUrl)
    try { ([uri]$BaseUrl).IsLoopback } catch { $false }
}

function Get-LmAuthHeader {
    @{ Authorization = "Bearer $script:LmAuthToken" }
}

function Test-LmInteractive {
    # Prompts only make sense with a console user (not piped input, e.g. scripted `claude -p`).
    [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Get-LmSettingsConnection {
    # The server URL and API key stored in a settings file ($null for anything missing).
    param([string]$SettingsPath)
    $conn = [pscustomobject]@{ BaseUrl = $null; Token = $null }
    if (Test-Path $SettingsPath) {
        try {
            $e = (Get-Content $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).env
            if ($e.ANTHROPIC_BASE_URL)   { $conn.BaseUrl = "$($e.ANTHROPIC_BASE_URL)".TrimEnd('/') }
            if ($e.ANTHROPIC_AUTH_TOKEN) { $conn.Token   = "$($e.ANTHROPIC_AUTH_TOKEN)" }
        } catch { }
    }
    $conn
}

# The settings file is what Claude Code actually uses, so it wins over the environment variables,
# which only seed a new file.
$script:LmInitialConnection = Get-LmSettingsConnection $script:LmDefaultSettings
if ($script:LmInitialConnection.BaseUrl) { $script:LmDefaultBaseUrl = $script:LmInitialConnection.BaseUrl }
if ($script:LmInitialConnection.Token)   { $script:LmAuthToken = $script:LmInitialConnection.Token }

function ConvertTo-LmBaseUrl {
    # "192.168.1.50", "host:1234" or "http://host:1234/" -> "http://host:1234" ($null if invalid).
    # A bare host or IP gets LM Studio's default port, 1234.
    param([string]$Address)
    $a = "$Address".Trim().TrimEnd('/')
    if ($a -notmatch '^(?<scheme>https?://)?(?<host>[A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:(?<port>\d{1,5}))?$') { return $null }
    $scheme = if ($Matches.scheme) { $Matches.scheme } else { 'http://' }
    $port   = if ($Matches.port) { ":$($Matches.port)" } elseif (-not $Matches.scheme) { ':1234' } else { '' }
    "$scheme$($Matches.host)$port"
}

function Read-LmServerAddress {
    # Returns a normalized base URL, $Default when the answer is blank, or $null to cancel.
    param([string]$Default)
    $hint = if ($Default) { "blank keeps $Default" } else { 'blank cancels' }
    while ($true) {
        $answer = Read-Host "LM Studio host or IP, e.g. 192.168.1.50 or 192.168.1.50:1234 ($hint)"
        if (-not $answer.Trim()) { return $Default }
        $url = ConvertTo-LmBaseUrl $answer
        if ($url) { return $url }
        Write-Warning "'$answer' is not a valid host name, IP address, or URL."
    }
}

function Read-LmApiKey {
    # Returns the typed API key, or $null if left blank.
    $secure = Read-Host 'LM Studio API key (input hidden, blank cancels)' -AsSecureString
    $plain  = [System.Net.NetworkCredential]::new('', $secure).Password
    if ($plain) { $plain } else { $null }
}

function Get-LmStudioServerState {
    <#
    .SYNOPSIS
        'Ready', 'Unauthorized' (the server answered but wants an API key), or 'Unreachable'.
    #>
    param([string]$BaseUrl = $script:LmDefaultBaseUrl, [int]$TimeoutSec = 10)
    try {
        $null = Invoke-RestMethod -Uri "$BaseUrl/v1/models" -Headers (Get-LmAuthHeader) -TimeoutSec $TimeoutSec -ErrorAction Stop
        return 'Ready'
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -in 401, 403) { return 'Unauthorized' }
        return 'Unreachable'
    }
}

function Test-LmStudioServer {
    param([string]$BaseUrl = $script:LmDefaultBaseUrl, [int]$TimeoutSec = 10)
    (Get-LmStudioServerState -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec) -eq 'Ready'
}

function Start-LmStudioServer {
    param([string]$BaseUrl = $script:LmDefaultBaseUrl, [int]$WaitSec = 60)

    $state = Get-LmStudioServerState -BaseUrl $BaseUrl
    if ($state -eq 'Ready') { return $true }
    if ($state -eq 'Unauthorized') {
        Write-Warning "LM Studio at $BaseUrl requires an API key. Run Set-ClaudeLocalApiKey."
        return $false
    }

    if (-not (Test-LmLocalUrl $BaseUrl)) {
        Write-Warning "LM Studio is not reachable at $BaseUrl. On that machine, start the server with 'Serve on Local Network' enabled and allow the port through its firewall."
        return $false
    }

    $lms = Get-LmsExe
    if (-not $lms) {
        Write-Warning "LM Studio server is not reachable at $BaseUrl and the 'lms' CLI was not found. Start it in LM Studio under Developer > Start server."
        return $false
    }

    $port = ([uri]$BaseUrl).Port
    Write-Host "LM Studio server not reachable; running 'lms server start --port $port'..." -ForegroundColor Yellow
    & $lms server start --port $port | Out-Host

    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        # An auth-protected server answering 401 is up; the caller deals with the key.
        if ((Get-LmStudioServerState -BaseUrl $BaseUrl -TimeoutSec 5) -ne 'Unreachable') { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Warning "LM Studio server did not come up at $BaseUrl within $WaitSec seconds."
    return $false
}

function Resolve-ClaudeLocalServer {
    <#
    .SYNOPSIS
        Find a usable LM Studio server and return its base URL ($null if none).
    .DESCRIPTION
        1. Use $BaseUrl if it answers.
        2. If it is this machine and not running, try `lms server start`.
        3. If LM Studio is missing here, `lms` fails, or the server is not reachable, ask for the
           IP address / host name of a machine running LM Studio.
        4. If the server wants an API key, ask for it (input hidden).
        $script:LmAuthToken holds the key that worked. Nothing is saved to disk here.
        Prompts are skipped (with a warning) when there is no interactive console.
    #>
    param(
        [Parameter(Mandatory)] [string]$BaseUrl,
        [switch]$PromptForServer,
        [switch]$PromptForApiKey
    )

    $interactive = Test-LmInteractive
    $origToken = $script:LmAuthToken

    if (($PromptForServer -or $PromptForApiKey) -and -not $interactive) {
        Write-Warning 'No interactive console; ignoring the request to prompt for the server address or API key.'
        $PromptForServer = $PromptForApiKey = $false
    }
    if ($PromptForServer) { $BaseUrl = Read-LmServerAddress -Default $BaseUrl }
    if ($PromptForApiKey) {
        $key = Read-LmApiKey
        if ($key) { $script:LmAuthToken = $key }
    }

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $state = Get-LmStudioServerState -BaseUrl $BaseUrl
        if ($state -eq 'Unreachable' -and (Test-LmLocalUrl $BaseUrl)) {
            if (Start-LmStudioServer -BaseUrl $BaseUrl) { $state = Get-LmStudioServerState -BaseUrl $BaseUrl }
        }

        switch ($state) {
            'Ready' { return $BaseUrl }
            'Unauthorized' {
                if (-not $interactive) {
                    Write-Warning "LM Studio at $BaseUrl requires an API key. Run Set-ClaudeLocalApiKey."
                    $script:LmAuthToken = $origToken
                    return $null
                }
                Write-Host "LM Studio at $BaseUrl requires an API key (LM Studio > Developer > Server Settings > Require Authentication)." -ForegroundColor Yellow
                $key = Read-LmApiKey
                if (-not $key) { $script:LmAuthToken = $origToken; return $null }
                $script:LmAuthToken = $key
            }
            default {
                if (-not $interactive) {
                    Write-Warning "LM Studio is not reachable at $BaseUrl."
                    $script:LmAuthToken = $origToken
                    return $null
                }
                Write-Host "LM Studio is not reachable at $BaseUrl. If it runs on another machine, enter that machine's address." -ForegroundColor Yellow
                $next = Read-LmServerAddress
                if (-not $next) { $script:LmAuthToken = $origToken; return $null }
                $BaseUrl = $next
            }
        }
    }

    Write-Warning 'Giving up after repeated failures.'
    $script:LmAuthToken = $origToken
    return $null
}

function Get-LmStudioModel {
    <#
    .SYNOPSIS
        Chat-capable models the server exposes (embeddings are excluded), merged with
        `lms ls` details (display name, params, tool-use training) when the CLI is available.
    #>
    param([string]$BaseUrl = $script:LmDefaultBaseUrl)

    # /api/v0/models carries type, arch, quant and context; /v1/models is the fallback.
    $models = $null
    try {
        $models = (Invoke-RestMethod -Uri "$BaseUrl/api/v0/models" -Headers (Get-LmAuthHeader) -TimeoutSec 15 -ErrorAction Stop).data |
            Where-Object { $_.type -in 'llm', 'vlm' }
    } catch {
        $models = (Invoke-RestMethod -Uri "$BaseUrl/v1/models" -Headers (Get-LmAuthHeader) -TimeoutSec 15 -ErrorAction Stop).data |
            Where-Object { $_.id -notmatch 'embed' }
    }

    $lmsInfo = @{}
    # `lms ls` lists this machine's models, so it is only merged in for a local server.
    $lms = if (Test-LmLocalUrl $BaseUrl) { Get-LmsExe }
    if ($lms) {
        try {
            $json = & $lms ls --json 2>$null | Out-String
            foreach ($m in ($json | ConvertFrom-Json)) { $lmsInfo[$m.modelKey] = $m }
        } catch { }
    }

    foreach ($m in $models) {
        $info = $lmsInfo[$m.id]
        [pscustomobject]@{
            Id                     = $m.id
            DisplayName            = if ($info) { $info.displayName } else { $null }
            Type                   = $m.type
            Arch                   = $m.arch
            Quantization           = $m.quantization
            Params                 = if ($info) { $info.paramsString } else { $null }
            MaxContext             = $m.max_context_length
            State                  = $m.state
            TrainedForToolUse      = if ($info) { $info.trainedForToolUse } else { $null }
            IndexedModelIdentifier = if ($info) { $info.indexedModelIdentifier } else { $null }
        }
    }
}

function New-LmPickerOption {
    param($Model)

    $label = $Model.DisplayName
    if (-not $label) {
        # "qwen/qwen3-4b" -> "Qwen3 4B"
        $label = (($Model.Id -split '/')[-1] -split '[-_]' | ForEach-Object {
            if ($_ -match '^\d+(\.\d+)?[bBmM]$') { $_.ToUpper() }
            elseif ($_.Length) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }
        }) -join ' '
    }

    $bits = @()
    if ($Model.Params)       { $bits += $Model.Params }
    if ($Model.Arch)         { $bits += $Model.Arch }
    if ($Model.Quantization) { $bits += $Model.Quantization }
    if ($Model.MaxContext)   { $bits += ('{0}K ctx' -f [math]::Round($Model.MaxContext / 1024)) }
    if ($Model.TrainedForToolUse -eq $false) { $bits += 'not trained for tool use' }
    $bits += 'auto-added'

    [ordered]@{ model = $Model.Id; label = $label; description = ($bits -join ', ') }
}

$script:LmModelSlots = 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL'

function New-LmSettingsObject {
    # A new settings file. With -Model, every model slot (including background and subagent
    # work) points at that LM Studio model so nothing ever asks for an Anthropic model.
    param([string]$BaseUrl, [string]$Token, [string]$Model)
    $e = [ordered]@{
        ANTHROPIC_BASE_URL                       = $BaseUrl
        ANTHROPIC_AUTH_TOKEN                     = $Token
        API_TIMEOUT_MS                           = '3000000'
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        CLAUDE_CODE_ATTRIBUTION_HEADER           = '0'
    }
    if ($Model) { foreach ($k in $script:LmModelSlots) { $e[$k] = $Model } }
    $s = [ordered]@{ env = [pscustomobject]$e }
    if ($Model) { $s.model = $Model }
    $s.modelPicker = [pscustomobject]@{ replaceBuiltInOptions = $true; options = @() }
    [pscustomobject]$s
}

function Save-LmSettingsFile {
    # Back up an existing file (timestamped, newest -BackupsToKeep kept), write the new one, log it.
    # A failed backup aborts the write.
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string]$SettingsPath,
        [Parameter(Mandatory)] [string[]]$Changes,
        [switch]$IsNew,
        [int]$BackupsToKeep = 10
    )

    $backup = $null
    $pruned = @()
    try {
        $dir = Split-Path $SettingsPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not $IsNew) {
            # Milliseconds keep two writes in the same second from overwriting each other's backup.
            $backup = '{0}.{1:yyyyMMdd-HHmmss-fff}.bak' -f $SettingsPath, (Get-Date)
            Copy-Item $SettingsPath $backup -ErrorAction Stop
            $pruned = @(Get-ChildItem "$SettingsPath.*.bak" | Sort-Object Name -Descending |
                Select-Object -Skip $BackupsToKeep)
            $pruned | Remove-Item
        }
        $json = $Settings | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($SettingsPath, $json, [Text.UTF8Encoding]::new($false))
    } catch {
        Write-LmLog -Component 'Settings' -Severity 3 -Message "Failed to update ${SettingsPath}: $($_.Exception.Message). Pending changes not applied: $($Changes -join '; ')"
        throw
    }

    Write-LmLog -Component 'Settings' -Message ("{0} {1} ({2} change(s))" -f $(if ($IsNew) { 'Created' } else { 'Updated' }), $SettingsPath, $Changes.Count)
    if ($backup) { Write-LmLog -Component 'Settings' -Message "Backed up previous file to $backup" }
    foreach ($p in $pruned) { Write-LmLog -Component 'Settings' -Message "Deleted old backup $($p.FullName) (keeping newest $BackupsToKeep)" }
    foreach ($c in $Changes) { Write-LmLog -Component 'Settings' -Message $c }

    Write-Host "Updated $SettingsPath" -ForegroundColor Cyan
    if ($backup) { Write-Host "  backup: $backup" -ForegroundColor DarkGray }
    Write-Host "  log:    $script:LmLogPath" -ForegroundColor DarkGray
}

function Update-LmSettingsEnv {
    <#
    .SYNOPSIS
        Set values in the settings file's "env" block (creating a minimal file if needed).
        Returns $true if the file was written; nothing is written when the values already match.
        API key values are never logged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$SettingsPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Values
    )

    $isNew = -not (Test-Path $SettingsPath)
    if ($isNew) {
        $settings = New-LmSettingsObject -BaseUrl $script:LmDefaultBaseUrl -Token $script:LmAuthToken
    } else {
        try {
            $settings = Get-Content $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Could not read ${SettingsPath}; nothing changed. $($_.Exception.Message)"
        }
        if (-not $settings.PSObject.Properties['env']) {
            $settings | Add-Member env ([pscustomobject]@{})
        }
    }

    $changes = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Values.Keys) {
        $old = $settings.env.PSObject.Properties[$k]
        if ($old -and "$($old.Value)" -eq "$($Values[$k])") { continue }
        $settings.env | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] -Force
        $changes.Add($(if ($k -match 'TOKEN|KEY') { "Set env.$k (value not logged)" } else { "Set env.$k to '$($Values[$k])'" }))
    }
    if (-not $changes.Count) { return $false }

    if ($PSCmdlet.ShouldProcess($SettingsPath, "Set $($Values.Keys -join ', ')")) {
        Save-LmSettingsFile -Settings $settings -SettingsPath $SettingsPath -Changes $changes -IsNew:$isNew
        return $true
    }
    return $false
}

function Update-ClaudeLocalSettings {
    <#
    .SYNOPSIS
        Add any LM Studio models missing from the settings file's /model picker.
    .DESCRIPTION
        Before changing an existing file it is copied to <file>.<yyyyMMdd-HHmmss-fff>.bak;
        only the newest -BackupsToKeep backups are kept. Nothing is written if nothing changed.
    .PARAMETER Prune
        Also remove picker entries whose model no longer exists in LM Studio.
    .OUTPUTS
        The list of chat models found (so callers don't need to query again).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$SettingsPath = $script:LmDefaultSettings,
        [string]$BaseUrl = $script:LmDefaultBaseUrl,
        [switch]$Prune,
        [int]$BackupsToKeep = 10
    )

    # The saved key (if any) is what Claude Code will send, so use it for the model query too.
    $saved = Get-LmSettingsConnection $SettingsPath
    if ($saved.Token) { $script:LmAuthToken = $saved.Token }

    $models = @(Get-LmStudioModel -BaseUrl $BaseUrl)
    if (-not $models) {
        Write-Warning 'LM Studio reported no chat models; settings file left unchanged.'
        return
    }
    $ids = $models.Id

    if (Test-Path $SettingsPath) {
        # Stop rather than continue with nothing and overwrite a file we couldn't read.
        try {
            $settings = Get-Content $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Could not read ${SettingsPath}; nothing changed. $($_.Exception.Message)"
        }
    } else {
        Write-Host "Creating $SettingsPath" -ForegroundColor Cyan
        $settings = New-LmSettingsObject -BaseUrl $BaseUrl -Token $script:LmAuthToken -Model $ids[0]
    }

    $fileUrl = "$($settings.env.ANTHROPIC_BASE_URL)".TrimEnd('/')
    if ($fileUrl -and $fileUrl -ne $BaseUrl.TrimEnd('/')) {
        Write-Warning "Models came from $BaseUrl but $SettingsPath sends Claude Code to $fileUrl. Run Set-ClaudeLocalServer to change it."
    }

    if (-not $settings.PSObject.Properties['modelPicker']) {
        $settings | Add-Member modelPicker ([pscustomobject]@{ replaceBuiltInOptions = $true; options = @() })
    }
    $options = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @($settings.modelPicker.options)) { if ($o) { $options.Add($o) } }

    $isNew   = -not (Test-Path $SettingsPath)
    $changes = [System.Collections.Generic.List[string]]::new()   # logged only once the file is written

    # A file created before any model was known (e.g. by Set-ClaudeLocalApiKey) has no default yet.
    if (-not $settings.PSObject.Properties['model'] -or -not $settings.model) {
        $settings | Add-Member -NotePropertyName model -NotePropertyValue $ids[0] -Force
        $changes.Add("Set default model to '$($ids[0])'")
    }

    foreach ($m in $models) {
        if ($options.model -notcontains $m.Id) {
            $opt = New-LmPickerOption $m
            Write-Host ("  + {0}  ({1})" -f $m.Id, $opt.description) -ForegroundColor Green
            $options.Add([pscustomobject]$opt)
            $changes.Add("Added picker entry '$($m.Id)' (label '$($opt.label)', $($opt.description))")
        }
    }

    foreach ($o in @($options)) {
        if ($ids -notcontains $o.model) {
            if ($Prune) {
                Write-Host "  - $($o.model)  (no longer in LM Studio)" -ForegroundColor Red
                $null = $options.Remove($o)
                $changes.Add("Removed picker entry '$($o.model)' (no longer in LM Studio)")
            } else {
                Write-Warning "Picker entry '$($o.model)' is not in LM Studio (use -Prune to remove it)."
            }
        }
    }

    # Warn about default/background slots that point at missing models.
    $slots = [ordered]@{ 'model' = $settings.model }
    foreach ($k in 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL',
                   'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL') {
        if ($settings.env.PSObject.Properties[$k]) { $slots["env.$k"] = $settings.env.$k }
    }
    foreach ($s in $slots.GetEnumerator()) {
        if ($s.Value -and $s.Value -ne 'default_model' -and $ids -notcontains $s.Value) {
            Write-Warning "$($s.Key) = '$($s.Value)' is not a model LM Studio knows about."
        }
    }

    if ($changes.Count) {
        $settings.modelPicker.options = $options.ToArray()
        if ($PSCmdlet.ShouldProcess($SettingsPath, 'Write updated model list')) {
            Save-LmSettingsFile -Settings $settings -SettingsPath $SettingsPath -Changes $changes -IsNew:$isNew -BackupsToKeep $BackupsToKeep
        }
    } else {
        Write-Host 'Model list already up to date.' -ForegroundColor DarkGray
    }

    $models
}

function Set-ClaudeLocalServer {
    <#
    .SYNOPSIS
        Point the settings file at a different LM Studio machine (prompts for the address).
    .DESCRIPTION
        Accepts an IP address, host name, host:port, or URL; a bare host gets LM Studio's
        default port 1234. Only ANTHROPIC_BASE_URL changes. Use -Address localhost to switch back.
    .EXAMPLE
        Set-ClaudeLocalServer 192.168.1.50
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Address,
        [string]$SettingsPath = $script:LmDefaultSettings
    )

    if (-not $Address) { $Address = Read-LmServerAddress }
    if (-not $Address) { Write-Host 'No address entered; nothing changed.' -ForegroundColor DarkGray; return }
    $url = ConvertTo-LmBaseUrl $Address
    if (-not $url) { throw "'$Address' is not a valid host name, IP address, or URL." }

    $saved = Get-LmSettingsConnection $SettingsPath
    if ($saved.Token) { $script:LmAuthToken = $saved.Token }
    switch (Get-LmStudioServerState -BaseUrl $url) {
        'Ready'        { Write-Host "LM Studio answered at $url." -ForegroundColor Green }
        'Unauthorized' { Write-Warning "LM Studio at $url requires an API key that differs from the saved one. Run Set-ClaudeLocalApiKey." }
        default        { Write-Warning "Nothing answered at $url yet. Saving it anyway; check that the server is running with 'Serve on Local Network' and the firewall allows the port." }
    }

    if (Update-LmSettingsEnv -SettingsPath $SettingsPath -Values ([ordered]@{ ANTHROPIC_BASE_URL = $url }) -WhatIf:$WhatIfPreference) {
        $script:LmDefaultBaseUrl = $url
    } else {
        Write-Host "Server already set to $url." -ForegroundColor DarkGray
    }
}

function Set-ClaudeLocalApiKey {
    <#
    .SYNOPSIS
        Save the API key LM Studio requires (Developer > Server Settings > Require Authentication).
    .DESCRIPTION
        Prompts with hidden input unless -ApiKey is given. The key is written to the settings file
        as ANTHROPIC_AUTH_TOKEN in plain text, so keep that file private. -Clear resets it to the
        placeholder 'lmstudio' for servers without authentication. The key is never logged.
    .EXAMPLE
        Set-ClaudeLocalApiKey
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [securestring]$ApiKey,
        [switch]$Clear,
        [string]$SettingsPath = $script:LmDefaultSettings
    )

    if ($Clear) {
        $plain = 'lmstudio'
    } else {
        if (-not $ApiKey) { $ApiKey = Read-Host 'LM Studio API key (input hidden)' -AsSecureString }
        $plain = [System.Net.NetworkCredential]::new('', $ApiKey).Password
        if (-not $plain) { Write-Host 'No key entered; nothing changed.' -ForegroundColor DarkGray; return }
    }

    $saved = Get-LmSettingsConnection $SettingsPath
    $url = if ($saved.BaseUrl) { $saved.BaseUrl } else { $script:LmDefaultBaseUrl }

    $previous = $script:LmAuthToken
    $script:LmAuthToken = $plain
    switch (Get-LmStudioServerState -BaseUrl $url) {
        'Ready'        { Write-Host "LM Studio at $url accepted the key." -ForegroundColor Green }
        'Unauthorized' { Write-Warning "LM Studio at $url rejected this key. Saving it anyway." }
        default        { Write-Warning "LM Studio is not reachable at $url, so the key could not be checked. Saving it anyway." }
    }

    if (-not (Update-LmSettingsEnv -SettingsPath $SettingsPath -Values ([ordered]@{ ANTHROPIC_AUTH_TOKEN = $plain }) -WhatIf:$WhatIfPreference)) {
        $script:LmAuthToken = $previous
        Write-Host 'API key unchanged.' -ForegroundColor DarkGray
    }
}

function Get-LmChatTemplate {
    <#
    .SYNOPSIS
        The chat template LM Studio will use for a model: the user override saved from
        My Models > settings, otherwise the template embedded in the GGUF.
    #>
    param([Parameter(Mandatory)] [string]$IndexedModelIdentifier)

    $override = Join-Path $script:LmHome ".internal\user-concrete-model-default-config\$IndexedModelIdentifier.json"
    if (Test-Path $override) {
        $cfg = Get-Content $override -Raw | ConvertFrom-Json
        $field = $cfg.load.fields | Where-Object key -eq 'llm.load.promptTemplate' | Select-Object -First 1
        if ($field -and $field.value.jinjaPromptTemplate.template) {
            return [pscustomobject]@{ Source = 'override'; Path = $override; Template = $field.value.jinjaPromptTemplate.template }
        }
    }

    $indexPath = Join-Path $script:LmHome '.internal\model-index-cache.json'
    if (Test-Path $indexPath) {
        if (-not $script:LmIndexCache -or $script:LmIndexCacheTime -ne (Get-Item $indexPath).LastWriteTime) {
            $script:LmIndexCache     = Get-Content $indexPath -Raw | ConvertFrom-Json
            $script:LmIndexCacheTime = (Get-Item $indexPath).LastWriteTime
        }
        $entry = $script:LmIndexCache.models | Where-Object indexedModelIdentifier -eq $IndexedModelIdentifier | Select-Object -First 1
        if ($entry -and $entry.metadata.gguf.chatTemplate) {
            return [pscustomobject]@{ Source = 'gguf default'; Path = $indexPath; Template = $entry.metadata.gguf.chatTemplate }
        }
    }
    return $null
}

function Invoke-LmTemplateProbe {
    # Sends one tiny request; returns $null on success or the error text.
    param([string]$Uri, [hashtable]$Body, [int]$TimeoutSec)
    try {
        $null = Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json' `
            -Headers @{ 'x-api-key' = $script:LmAuthToken; 'anthropic-version' = '2023-06-01'; Authorization = "Bearer $script:LmAuthToken" } `
            -Body ($Body | ConvertTo-Json -Depth 20) -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $null
    } catch {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($msg -match 'Jinja Exception: ([^"\\]+)') { return "Jinja Exception: $($Matches[1].Trim())" }
        try { $e = $msg | ConvertFrom-Json; if ($e.error.message) { $msg = $e.error.message } elseif ($e.error) { $msg = "$($e.error)" } } catch { }
        return $msg
    }
}

function Test-LmChatTemplate {
    <#
    .SYNOPSIS
        Check whether each model's chat template will accept Claude Code's requests.
    .DESCRIPTION
        Static (default): reads the template LM Studio will use (user override or GGUF
        default), lists its raise_exception rules and flags the ones known to break
        Claude Code. Needs no server and loads nothing.

        -Live: also sends small requests shaped like Claude Code's to the server:
          1. a system message in the middle of the conversation   (/v1/chat/completions)
          2. two user turns in a row                              (/v1/chat/completions)
          3. system prompt + tool_use / tool_result round trip    (/v1/messages, what Claude Code calls)
        This JIT-loads each model, so it is slow and uses VRAM; models it loaded are unloaded after.
    .EXAMPLE
        Test-LmChatTemplate
    .EXAMPLE
        Test-LmChatTemplate -Model qwen3.5-4b -Live
    #>
    param(
        [string[]]$Model,
        [switch]$Live,
        [string]$BaseUrl = $script:LmDefaultBaseUrl,
        [int]$TimeoutSec = 600
    )

    if (-not (Test-LmLocalUrl $BaseUrl)) {
        throw "Test-LmChatTemplate reads LM Studio's local files and CLI, so it only works against a local server. Run it on the LM Studio machine."
    }
    $lms = Get-LmsExe
    if (-not $lms) { throw "The 'lms' CLI is required to map models to their templates." }
    $all = (& $lms ls --json 2>$null | Out-String | ConvertFrom-Json) | Where-Object type -eq 'llm'
    if ($Model) {
        $missing = $Model | Where-Object { $all.modelKey -notcontains $_ }
        if ($missing) { Write-Warning "Unknown model(s): $($missing -join ', ')" }
        $all = $all | Where-Object { $Model -contains $_.modelKey }
    }

    if ($Live -and -not (Start-LmStudioServer -BaseUrl $BaseUrl)) { throw 'LM Studio server is not running.' }

    foreach ($m in $all) {
        $tpl = Get-LmChatTemplate -IndexedModelIdentifier $m.indexedModelIdentifier
        $rules = @()
        $problems = @()
        if ($tpl) {
            $rules = [regex]::Matches($tpl.Template, "raise_exception\(\s*(['""])(.*?)\1") |
                ForEach-Object { $_.Groups[2].Value } | Sort-Object -Unique
            foreach ($r in $script:LmBadTemplateRules) {
                if ($tpl.Template -match [regex]::Escape($r.Pattern)) { $problems += "$($r.Pattern) -- $($r.Why)" }
            }
        }

        $probe = $null
        if ($Live) {
            Write-Host "Probing $($m.modelKey) (loading may take a while)..." -ForegroundColor DarkGray
            $wasLoaded = @(& $lms ps --json 2>$null | Out-String | ConvertFrom-Json).identifier -contains $m.modelKey
            $chat = "$BaseUrl/v1/chat/completions"
            $probe = [ordered]@{
                'mid-conversation system' = Invoke-LmTemplateProbe $chat -TimeoutSec $TimeoutSec -Body @{
                    model = $m.modelKey; max_tokens = 8; stream = $false
                    messages = @(
                        @{ role = 'system';    content = 'You are a test.' }
                        @{ role = 'user';      content = 'Hi' }
                        @{ role = 'assistant'; content = 'Hello.' }
                        @{ role = 'system';    content = 'Extra system content mid-conversation.' }
                        @{ role = 'user';      content = 'Reply with OK.' }
                    ) }
                'consecutive user turns' = Invoke-LmTemplateProbe $chat -TimeoutSec $TimeoutSec -Body @{
                    model = $m.modelKey; max_tokens = 8; stream = $false
                    messages = @(
                        @{ role = 'system'; content = 'You are a test.' }
                        @{ role = 'user';   content = 'First user turn.' }
                        @{ role = 'user';   content = 'Second user turn. Reply with OK.' }
                    ) }
                'tool round trip (/v1/messages)' = Invoke-LmTemplateProbe "$BaseUrl/v1/messages" -TimeoutSec $TimeoutSec -Body @{
                    model = $m.modelKey; max_tokens = 8
                    system = 'You are a test.'
                    tools = @(@{ name = 'get_time'; description = 'Returns the time'; input_schema = @{ type = 'object'; properties = @{} } })
                    messages = @(
                        @{ role = 'user';      content = 'What time is it?' }
                        @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'toolu_1'; name = 'get_time'; input = @{} }) }
                        @{ role = 'user';      content = @(
                                @{ type = 'tool_result'; tool_use_id = 'toolu_1'; content = '12:00' }
                                @{ type = 'text'; text = 'Reply with OK.' }) }
                    ) }
            }
            if (-not $wasLoaded) { & $lms unload $m.modelKey 2>$null | Out-Null }
        }

        $status = if (-not $tpl) { 'NO TEMPLATE FOUND' }
                  elseif ($probe -and @($probe.Values | Where-Object { $_ }).Count) { 'FAIL' }
                  elseif ($problems) { if ($Live) { 'WARN (rule present, live tests passed)' } else { 'NEEDS FIX' } }
                  else { 'OK' }
        $color = switch -Wildcard ($status) { 'OK' { 'Green' } 'WARN*' { 'Yellow' } default { 'Red' } }

        Write-Host ''
        Write-Host ("{0}  [{1}]" -f $m.modelKey, $status) -ForegroundColor $color
        if ($tpl) { Write-Host "  template: $($tpl.Source)" -ForegroundColor DarkGray }
        if ($m.trainedForToolUse -eq $false) { Write-Host '  note: LM Studio says this model is not trained for tool use' -ForegroundColor Yellow }
        foreach ($p in $problems) { Write-Host "  ! $p" -ForegroundColor Red }
        if ($probe) {
            foreach ($t in $probe.GetEnumerator()) {
                if ($t.Value) { Write-Host "  x $($t.Key): $($t.Value)" -ForegroundColor Red }
                else          { Write-Host "  v $($t.Key)" -ForegroundColor Green }
            }
        }

        [pscustomobject]@{
            Model          = $m.modelKey
            Status         = $status
            TemplateSource = if ($tpl) { $tpl.Source } else { $null }
            TemplatePath   = if ($tpl) { $tpl.Path } else { $null }
            Problems       = $problems
            Rules          = $rules
            LiveResults    = $probe
        }
    }
}

function Start-ClaudeLocal {
    <#
    .SYNOPSIS
        Ensure LM Studio is running, sync models into the settings file, launch Claude Code.
    .DESCRIPTION
        Every argument not listed below is passed straight to claude, e.g.
          claude-local --continue
          claude-local -p "explain this repo"
        The script's own switches are prefixed with -Lm so they never collide with claude's flags.

        Script switches:
          -LmModel <id>          Start with this model (passed to claude as --model).
          -LmSkipUpdate          Don't query LM Studio for new models.
          -LmCheckTemplates      Run the static chat-template check before launching.
          -LmSettingsPath <path> Settings file (default ~\.claude\lmstudio.settings.json).
          -LmBaseUrl <url>       LM Studio server to use (saved to the settings file). Default: the URL
                                 in the settings file, else $env:CLAUDELOCAL_BASEURL, else localhost:1234.
          -LmSetServer           Prompt for the IP address / host of the LM Studio machine.
          -LmSetApiKey           Prompt for LM Studio's API key (hidden) and save it.

        If LM Studio is not installed here, `lms server start` fails, or the server is not
        reachable, you are asked for the address of a machine that runs it, and the settings
        file is updated to that address. If the server requires an API key you are asked for it.
        Claude Code is only ever launched against LM Studio; run plain `claude` for Anthropic.
    #>
    # No param() block: declared parameters would bind claude's arguments by position
    # (and [CmdletBinding()] adds common parameters that swallow flags like -p),
    # so the -Lm* switches are picked out of $args by hand.
    $LmModel = $null; $LmSkipUpdate = $false; $LmCheckTemplates = $false
    $LmSetServer = $false; $LmSetApiKey = $false
    $LmSettingsPath = $script:LmDefaultSettings; $LmBaseUrl = $null
    $passThru = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch -Regex ("$($args[$i])") {
            '^-LmModel$'          { $LmModel = $args[++$i]; continue }
            '^-LmSkipUpdate$'     { $LmSkipUpdate = $true; continue }
            '^-LmCheckTemplates$' { $LmCheckTemplates = $true; continue }
            '^-LmSetServer$'      { $LmSetServer = $true; continue }
            '^-LmSetApiKey$'      { $LmSetApiKey = $true; continue }
            '^-LmSettingsPath$'   { $LmSettingsPath = $args[++$i]; continue }
            '^-LmBaseUrl$'        { $LmBaseUrl = $args[++$i]; continue }
            default               { $passThru.Add($args[$i]) }
        }
    }

    # The settings file is what Claude Code will use, so its server and key are the starting point.
    $saved = Get-LmSettingsConnection $LmSettingsPath
    if ($saved.Token) { $script:LmAuthToken = $saved.Token }
    if ($LmBaseUrl) {
        $LmBaseUrl = ConvertTo-LmBaseUrl $LmBaseUrl
        if (-not $LmBaseUrl) { Write-Warning '-LmBaseUrl is not a valid host name, IP address, or URL.'; return }
    } else {
        $LmBaseUrl = if ($saved.BaseUrl) { $saved.BaseUrl } else { $script:LmDefaultBaseUrl }
    }

    $LmBaseUrl = Resolve-ClaudeLocalServer -BaseUrl $LmBaseUrl -PromptForServer:$LmSetServer -PromptForApiKey:$LmSetApiKey
    if (-not $LmBaseUrl) { return }

    # Save whatever address/key actually worked, so Claude Code connects the same way.
    if (Test-Path $LmSettingsPath) {
        $null = Update-LmSettingsEnv -SettingsPath $LmSettingsPath -Values ([ordered]@{
            ANTHROPIC_BASE_URL   = $LmBaseUrl
            ANTHROPIC_AUTH_TOKEN = $script:LmAuthToken
        })
    }

    $models = $null
    if (-not $LmSkipUpdate) {
        $models = Update-ClaudeLocalSettings -SettingsPath $LmSettingsPath -BaseUrl $LmBaseUrl
    }
    if (-not (Test-Path $LmSettingsPath)) {
        Write-Warning "Settings file not found: $LmSettingsPath"
        return
    }

    if ($LmCheckTemplates -and -not (Test-LmLocalUrl $LmBaseUrl)) {
        Write-Warning '-LmCheckTemplates only works against a local LM Studio; skipped.'
    } elseif ($LmCheckTemplates) {
        $bad = Test-LmChatTemplate -BaseUrl $LmBaseUrl | Where-Object Status -ne 'OK'
        if ($bad) { Write-Warning "Chat template issues: $($bad.Model -join ', '). See 'Fixing chat template errors' in ClaudeLocalSetup.md." }
    }

    $claudeArgs = @('--settings', $LmSettingsPath)
    if ($LmModel) {
        if (-not $models) { $models = @(Get-LmStudioModel -BaseUrl $LmBaseUrl) }
        if ($models.Id -notcontains $LmModel) {
            Write-Warning "'$LmModel' is not an LM Studio model id. Available: $($models.Id -join ', ')"
            return
        }
        $claudeArgs += @('--model', $LmModel)
    }

    & claude @claudeArgs @passThru
}

Set-Alias -Name claude-local -Value Start-ClaudeLocal
