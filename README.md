# ClaudeLocal

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) with models served by [LM Studio](https://lmstudio.ai/), on this machine or another one on your network. `claude-local` always launches Claude Code against LM Studio: it syncs LM Studio's models into a separate Claude Code settings file and points every model slot (default, background, and subagent) at LM Studio models. It never falls back to Anthropic; for that, run plain `claude`.

For detailed configuration examples, chat-template guidance, and troubleshooting, see [ClaudeLocalSetup.md](ClaudeLocalSetup.md).

## Requirements

- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) installed and available as `claude`.
- [LM Studio](https://lmstudio.ai/) 0.4.1 or later with at least one model downloaded, installed on this machine or on another one you can reach.
- On the machine running LM Studio, optionally the LM Studio CLI (`lms`) for starting the server automatically and for the template tools.

ClaudeLocal starts with `http://localhost:1234`. If LM Studio isn't installed here, `lms server start` doesn't work, or nothing answers, it asks for the IP address of the machine that runs it (see [below](#when-lm-studio-runs-on-another-machine)).

## Install

Clone this repository to a stable location. For example:

```powershell
git clone https://github.com/thejimoneil/ClaudeLocal.git "$HOME\ClaudeLocal"
```

Then dot-source the script from your PowerShell profile so its functions and `claude-local` command are available in each session:

```powershell
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force
}
notepad $PROFILE
```

Add this line to the profile, assuming the repository was cloned to `$HOME\ClaudeLocal`:

```powershell
. "$HOME\ClaudeLocal\ClaudeLocal.ps1"
```

Save the profile and reload it in the current terminal:

```powershell
. $PROFILE
```

To use another clone location, change the script path accordingly. Review the script before dot-sourcing it; PowerShell executes it with your user permissions.

## Usage

Start Claude Code with the LM Studio settings:

```powershell
claude-local
```

ClaudeLocal passes unrecognized arguments through to Claude Code. For example:

```powershell
claude-local --continue
claude-local -p "Summarize this project"
claude-local -LmModel qwen/qwen3-8b
```

ClaudeLocal-specific options:

| Option | Description |
| --- | --- |
| `-LmModel <id>` | Start with this model ID. It must be exposed by LM Studio. |
| `-LmSkipUpdate` | Do not query LM Studio or sync the model picker before launching. |
| `-LmCheckTemplates` | Run the static chat-template compatibility scan before launching. |
| `-LmSettingsPath <path>` | Use a settings file other than the default. |
| `-LmBaseUrl <url>` | Use this LM Studio server (IP, host, `host:port`, or URL) and save it to the settings file. Default: the settings file's URL, else `CLAUDELOCAL_BASEURL`, else `http://localhost:1234`. |
| `-LmSetServer` | Prompt for the IP address or host name of the LM Studio machine and save it. |
| `-LmSetApiKey` | Prompt for LM Studio's API key (input hidden) and save it. |

Other available commands:

```powershell
Get-LmStudioModel
Update-ClaudeLocalSettings
Update-ClaudeLocalSettings -Prune -WhatIf
Set-ClaudeLocalServer 192.168.1.50
Set-ClaudeLocalApiKey
Test-LmChatTemplate
Test-LmChatTemplate -Model qwen/qwen3-8b -Live
```

`-Prune` removes picker options for models no longer exposed by LM Studio. Review the proposed change with `-WhatIf` first. Live template tests send requests to the models and may load them, take time, and use VRAM.

## When LM Studio runs on another machine

You normally don't need to configure anything. When you run `claude-local`:

1. It checks the server in your settings file (`http://localhost:1234` the first time).
2. If that is this machine and the server isn't running, it tries `lms server start`.
3. If LM Studio isn't installed here, `lms` is missing or fails, or nothing answers, it asks for the IP address or host name of the machine running LM Studio. A bare address uses LM Studio's default port, so `192.168.1.50` becomes `http://192.168.1.50:1234`; you can also enter `host:port` or a full URL. Blank cancels.
4. Once a server answers, the address is saved to the settings file as `ANTHROPIC_BASE_URL`, so later runs go straight to it.

To change the machine later: `claude-local -LmSetServer`, or `Set-ClaudeLocalServer 192.168.1.60` (use `Set-ClaudeLocalServer localhost` to switch back).

Prompts need an interactive console. In scripts or piped sessions, `claude-local` warns and stops instead of asking.

On the LM Studio machine:

1. In **Developer > Server Settings**, enable **Serve on Local Network** so it listens beyond localhost.
2. Allow the server port (default 1234) through the firewall for your network only.
3. Don't expose the port to the internet. Use a VPN or an SSH tunnel (`ssh -L 1234:localhost:1234 user@host`, then keep using `localhost`) instead, because the connection is plain HTTP.

Limitations when LM Studio is remote:

- ClaudeLocal can't start the remote server; start LM Studio there yourself.
- Model details from `lms ls` (display names, parameter counts) are unavailable, so picker labels are derived from model IDs.
- `Test-LmChatTemplate` and `-LmCheckTemplates` read LM Studio's local files, so run them on the LM Studio machine.
- Model loading, context length, and RAM/VRAM are set on the LM Studio machine.
- Picker entries from a previous server stay until you run `Update-ClaudeLocalSettings -Prune`.

## API key (Require Authentication)

If you turn on **Require Authentication** in LM Studio's server settings, create an API token there and give it to ClaudeLocal. Any of these works:

- Just run `claude-local`. When the server answers that it needs a key, you are asked for it (hidden input), and it is saved once it is accepted.
- `claude-local -LmSetApiKey` or `Set-ClaudeLocalApiKey` to enter or replace the key at any time. `Set-ClaudeLocalApiKey -Clear` resets it to the placeholder `lmstudio` for servers without authentication.
- `Set-ClaudeLocalApiKey -ApiKey (Read-Host -AsSecureString)` to supply it from your own script.

The key is saved in the settings file as `ANTHROPIC_AUTH_TOKEN`, which is how Claude Code sends it to LM Studio. It is stored in plain text, so keep that file private. It is never written to the ClaudeLocal log. After a settings file exists it is the source of truth; `CLAUDELOCAL_BASEURL` and `CLAUDELOCAL_TOKEN` only supply the server and key when creating a new one.

## Files and privacy

- Settings: `$HOME\.claude\lmstudio.settings.json` by default. It is separate from this repository and is created/updated as needed. Existing settings are backed up (newest 10 kept) before every change.
- Script log: `$HOME\.claude\logs\ClaudeLocal.log`. The script logs settings changes and update errors, not conversation content, API keys, or chat-template probes. Logs over 2 MB are rolled to `ClaudeLocal.lo_`.
- LM Studio may keep its own server/request logs; consult LM Studio's **Developer > Logs**.

Do not commit your settings file or API key to this repository.

## License

No license has been added yet. Unless a license is included, GitHub users may view the repository but do not automatically receive permission to copy, distribute, or modify its contents. Add a license before inviting others to reuse the project.
