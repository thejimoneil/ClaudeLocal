# Using Claude Code with LM Studio Models

Oct 10, 2026 · @Jim O'Neil

## Overview

Claude Code can run against local models in LM Studio by pointing it at LM Studio's server through a separate settings file. LM Studio exposes an Anthropic-compatible `POST /v1/messages` endpoint, so no proxy is needed ([LM Studio docs](https://lmstudio.ai/docs/integrations/claude-code)). Because the local config lives in its own file, your normal Anthropic setup stays untouched.

Prerequisites:

- LM Studio 0.4.1 or later (the version that added `/v1/messages`).
- Claude Code installed.
- LM Studio's local server running on port 1234: start it in **Developer > Start server**, or run `lms server start --port 1234`.
- At least one model downloaded. Set a large context length (32K or more) when loading it, since Claude Code sends long prompts.

## Step 1: Create the settings file

Create a JSON file named `lmstudio.settings.json` in the `.claude` folder of your user profile:

```
%USERPROFILE%\.claude\lmstudio.settings.json
```

On a typical Windows machine that is `C:\Users\<you>\.claude\lmstudio.settings.json`. The `.claude` folder already exists if you have run Claude Code before.

Two values connect Claude Code to LM Studio:

- `ANTHROPIC_BASE_URL`: your LM Studio server, `http://localhost:1234`. Do not add `/v1`; Claude Code appends `/v1/messages` itself.
- `ANTHROPIC_AUTH_TOKEN`: any dummy string such as `lmstudio`. If you turned on **Require Authentication** in LM Studio's developer server settings, use the API token you created there instead.

Pick one of the two configs below for the file contents.

## Option A: Generic config (uses whatever model is loaded)

This config sends every request to the model you already have loaded in LM Studio. Every model slot is set to the placeholder `default_model`, so you never need to know a model ID. Load your model in LM Studio first, then start Claude Code.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:1234",
    "ANTHROPIC_AUTH_TOKEN": "lmstudio",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
    "ANTHROPIC_MODEL": "default_model",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "default_model",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "default_model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "default_model"
  }
}
```

What each setting does:

- `API_TIMEOUT_MS`: 3,000,000 ms (50 minutes), so slow local generation does not time out.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`: stops telemetry, error reporting and update checks to Anthropic.
- `CLAUDE_CODE_ATTRIBUTION_HEADER`: set to `0` as LM Studio recommends; it keeps the prompt prefix stable so LM Studio can reuse its cache.
- The four model variables point Claude Code's main, Sonnet, Opus and Haiku slots at the loaded model.

Changes from the original notes: the base URL had a stray link pasted into it, env values are now all strings (`"1"`, not `1`), and `ANTHROPIC_SMALL_FAST_MODEL` was dropped because `ANTHROPIC_DEFAULT_HAIKU_MODEL` replaced it.

## Option B: Custom config with your own model list

This config lists your downloaded models in Claude Code's `/model` picker, each with a label and description. When you pick one, Claude Code requests it by ID and LM Studio loads it on demand.

1. With the LM Studio server running, open `http://localhost:1234/v1/models` in a browser (or run `curl http://localhost:1234/v1/models`).
2. Copy each model's `id` value from the JSON response, for example `"id": "qwen/qwen3-4b"`.
3. Add one entry per model under `modelPicker.options`, with your own `label` and `description`.
4. Set `model` to the one you want by default, and point the Haiku and subagent variables at the models you want for background work.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:1234",
    "ANTHROPIC_AUTH_TOKEN": "lmstudio",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "qwen/qwen3-4b",
    "CLAUDE_CODE_SUBAGENT_MODEL": "qwen/qwen3.8-27b"
  },
  "model": "qwen/qwen3.8-27b",
  "modelPicker": {
    "replaceBuiltInOptions": true,
    "options": [
      { "model": "qwen/qwen3.8-27b", "label": "Qwen3.8 27B", "description": "Main coding model (default)" },
      { "model": "qwen3.8-27b-obliterated", "label": "Qwen3.8 27B Obliterated", "description": "Uncensored variant of Qwen3.8 27B" },
      { "model": "google/gemma-4-31b-qat", "label": "Gemma 4 31B QAT", "description": "Large Gemma model, quantization-aware trained" },
      { "model": "prism-ml/bonsai-27b", "label": "Bonsai 27B (Q1)", "description": "1-bit quant; currently crashes on ROCm, try Vulkan runtime" },
      { "model": "google/gemma-4-e4b", "label": "Gemma 4 E4B", "description": "Small, fast Gemma model" },
      { "model": "qwen3.5-4b", "label": "Qwen3.5 4B", "description": "Small, fast Qwen model" },
      { "model": "qwen/qwen3-4b", "label": "Qwen3 4B", "description": "Small, fast; used for background tasks" }
    ]
  }
}
```

Key settings:

- `model`: the model Claude Code starts with.
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`: the small model for background tasks such as titles and summaries. A 4B model keeps these fast.
- `CLAUDE_CODE_SUBAGENT_MODEL`: the model subagents use.
- `replaceBuiltInOptions: true`: hides the Anthropic models from the picker, since they won't work against LM Studio.

Each `model` value must match an `id` from `/v1/models` exactly, including the publisher prefix (`qwen/`, `google/`). A mismatch returns a model-not-found error. Loading a large model takes time, so the first prompt after switching is slow.

## Running Claude Code

Start Claude Code with the `--settings` switch pointing at your file. The syntax depends on your terminal.

Command Prompt (cmd):

```bat
claude --settings "%USERPROFILE%\.claude\lmstudio.settings.json"
```

PowerShell (it does not expand `%USERPROFILE%`):

```powershell
claude --settings "$env:USERPROFILE\.claude\lmstudio.settings.json"
```

Run `/model` inside the session to switch between the models in your picker.

To go back to Anthropic models, type `/exit` and start Claude Code normally with `claude`, without the `--settings` switch. The local settings apply only to sessions launched with that switch.

Optional shortcut: add a function to your PowerShell profile (`notepad $PROFILE`) so `claude-local` starts the LM Studio setup.

```powershell
function claude-local { claude --settings "$env:USERPROFILE\.claude\lmstudio.settings.json" @args }
```

## Fixing chat template errors

Some models fail on Claude Code's requests because their chat template only allows a system prompt as the very first message. Claude Code sends a long system prompt and can add more system content later in the conversation, so the template throws an error such as `System message must be at the beginning.` The fix is to edit that model's chat template in LM Studio.

### Find and edit the template

1. In LM Studio, open **My Models** (the library), select the model and open its settings (gear icon).
2. Turn on advanced settings and scroll toward the bottom to **Prompt Template / Chat Template**.
3. Copy the entire template into VS Code or Notepad++. Set the language to Jinja (or Django/Twig in Notepad++) for highlighting.
4. Search for `raise_exception`. Each match is a rule that can stop a request; match its message to the error LM Studio shows in **Developer > Logs**.
5. Edit the template (examples below), paste it back into LM Studio, then eject and reload the model.
6. Send a short prompt from Claude Code to confirm the error is gone.

Save the original template in a text file first so you can restore it.

### Example: allow system content anywhere

A typical Qwen-style template has this check inside its message loop:

```jinja
{%- for message in messages %}
    {%- if message.role == 'system' and not loop.first %}
        {{- raise_exception('System message must be at the beginning.') }}
    {%- endif %}
    ...
{%- endfor %}
```

Replace the top of the template with a block that gathers every system message into one system turn at the start, and make the loop skip system messages:

```jinja
{#- Collect all system messages into one block -#}
{%- set ns = namespace(sys='') %}
{%- for message in messages %}
    {%- if message.role == 'system' %}
        {%- if message.content is string %}
            {%- set ns.sys = ns.sys + message.content + '\n\n' %}
        {%- else %}
            {%- for part in message.content %}
                {%- if part.type == 'text' %}{%- set ns.sys = ns.sys + part.text + '\n\n' %}{%- endif %}
            {%- endfor %}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if ns.sys %}
    {{- '<|im_start|>system\n' + (ns.sys | trim) + '<|im_end|>\n' }}
{%- endif %}

{%- for message in messages %}
    {%- if message.role != 'system' %}
        ... the template's original handling of user, assistant and tool messages ...
    {%- endif %}
{%- endfor %}
```

Remove the template's original `if messages[0].role == 'system'` block too, or the system prompt is written twice. The `<|im_start|>` and `<|im_end|>` tokens are Qwen's; keep whatever tokens your model's template already uses.

### Example: model with no system role

Some templates reject the `system` role entirely (older Gemma templates raise `System role not supported`). Gather the system text as above, then prepend it to the first user message instead of writing a system turn:

```jinja
{%- set ns2 = namespace(done=false) %}
{%- for message in messages %}
    {%- if message.role == 'user' and not ns2.done and ns.sys %}
        {%- set content = ns.sys + (message.content if message.content is string else '') %}
        {%- set ns2.done = true %}
    {%- else %}
        {%- set content = message.content %}
    {%- endif %}
    ... render the turn with `content` in place of `message.content` ...
{%- endfor %}
```

If a template has a `Conversation roles must alternate` check, delete that `raise_exception` line as well; Claude Code can send two user turns in a row after tool results.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Connection refused | LM Studio server not running | Start the server in **Developer**, or run `lms server start --port 1234` |
| 401 Unauthorized | Require Authentication is on | Put your LM Studio API token in `ANTHROPIC_AUTH_TOKEN` |
| Model not found | `model` doesn't match an ID | Copy the exact `id` from `/v1/models` |
| Context length exceeded, or answers cut off | Model loaded with a small context | Reload the model with 32K or more context |
| Template or Jinja error in Logs | Chat template rejects the message layout | See **Fixing chat template errors** |
| Model talks about tools but never runs them | Model has weak tool-calling support | Use a model trained for tool use (recent Qwen or Gemma releases) |
| Settings ignored | Path didn't expand | Use `$env:USERPROFILE` in PowerShell, `%USERPROFILE%` in cmd |

Check **Developer > Logs** in LM Studio first; it shows each request Claude Code sends and the exact error.

## Sources

- [Use Claude Code with LM Studio](https://lmstudio.ai/docs/integrations/claude-code)
- [LM Studio Anthropic-compatible endpoints](https://lmstudio.ai/docs/developer/anthropic-compat)
