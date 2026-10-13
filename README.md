# ClaudeLocal

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) with models served locally by [LM Studio](https://lmstudio.ai/). ClaudeLocal syncs LM Studio models into a separate Claude Code settings file, then launches Claude Code using that configuration. Your normal Claude Code configuration remains separate.

For detailed configuration examples, chat-template guidance, and troubleshooting, see [ClaudeLocalSetup.md](ClaudeLocalSetup.md).

## Requirements

- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) installed and available as `claude`.
- [LM Studio](https://lmstudio.ai/) 0.4.1 or later, with at least one model downloaded.
- The LM Studio CLI (`lms`) for automatically starting the server and inspecting model/template details.

ClaudeLocal uses `http://localhost:1234` by default. Start the LM Studio server in **Developer > Start server**, or let ClaudeLocal start it through `lms`.

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
| `-LmBaseUrl <url>` | Use an LM Studio server URL other than `http://localhost:1234`. |

Other available commands:

```powershell
Get-LmStudioModel
Update-ClaudeLocalSettings
Update-ClaudeLocalSettings -Prune -WhatIf
Test-LmChatTemplate
Test-LmChatTemplate -Model qwen/qwen3-8b -Live
```

`-Prune` removes picker options for models no longer exposed by LM Studio. Review the proposed change with `-WhatIf` first. Live template tests send requests to the models and may load them, take time, and use VRAM.

## Files and privacy

- Settings: `$HOME\.claude\lmstudio.settings.json` by default. It is separate from this repository and is created/updated as needed. Existing settings are backed up before updates.
- Script log: `$HOME\.claude\logs\ClaudeLocal.log`. The script logs settings changes and update errors, not conversation content or chat-template probes. Logs over 2 MB are rolled to `ClaudeLocal.lo_`.
- LM Studio may keep its own server/request logs; consult LM Studio's **Developer > Logs**.

The generated settings use `lmstudio` as a placeholder auth token. If authentication is enabled in LM Studio, configure the actual token in the settings file. Do not commit personal settings or API tokens to this repository.

## License

No license has been added yet. Unless a license is included, GitHub users may view the repository but do not automatically receive permission to copy, distribute, or modify its contents. Add a license before inviting others to reuse the project.
