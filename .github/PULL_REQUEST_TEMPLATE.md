## What does this PR do?

<!-- Brief description of the change -->

## Type of change

- [ ] Bug fix
- [ ] New step or script
- [ ] Refactor / cleanup
- [ ] Documentation

## Checklist

- [ ] Ran `Invoke-ScriptAnalyzer` — no new violations under `PSAvoidGlobalAliases` or `PSAvoidUsingConvertToSecureStringWithPlainText`
- [ ] Script(s) follow the `-NonInteractive` / JSON output contract (emit structured JSON with a `Verdict` field when applicable)
- [ ] Exit codes are explicit (`exit 0` / `exit 1`)
- [ ] If a new step was added, `$script:Steps` in `Start-PreWipeToolkit.ps1` is updated
- [ ] If a new step was added, `$ScriptMap` in `Get-PreWipeSummary.ps1` is updated
- [ ] README updated if step numbers or script names changed
