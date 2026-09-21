# SessionStart hook helper.
# Emits structured JSON that injects docs/README.md as additionalContext so every
# session begins with the project documentation index loaded.
#
# Invoked from .claude/settings.json (exec form, no shell), so the environment is
# deterministic regardless of whether the default hook shell is bash or PowerShell.

$ErrorActionPreference = 'Stop'

# Force stdout to UTF-8 so non-ASCII (arrows, em-dashes) in the docs survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Locate the repo root: this script lives in <repo>/.claude/hooks/.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$readmePath = Join-Path $repoRoot 'docs/README.md'

if (-not (Test-Path -LiteralPath $readmePath)) {
    exit 0
}

$content = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)

$payload = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName     = 'SessionStart'
        additionalContext = $content
    }
}

[Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 5))
exit 0
