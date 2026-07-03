# Changelog

## v1.3.0 (2026-07) — Correctness overhaul ("the toolkit can actually fail now")

A full code review found that most failure paths reported success: the sync
check always said safe, escrow errors passed, backups claimed success without
copying, and every step's exit code read as 0. This release fixes all of it.

### Desktop app

The portable app ships the fixed scripts and gets its own round of fixes:

- The step host failed to parse on Windows PowerShell 5.1 (BOM-less encoding —
  the real root cause class behind "step host did not return a result"), and an
  exit-code shadowing bug recorded every failing step as DONE. Both fixed.
- The in-app "Ready to Wipe" banner now counts prior-session results like the
  HTML report does — re-running one passing step after a failed session no
  longer banners green.
- Reset Session clears per-step report JSONs too (console parity), so a stale
  prep can't feed the pre-wipe summary after a reset.
- Robustness: runs survive session.json write failures; a stray interactive
  prompt in a step fails fast instead of hanging the run forever; Cancel can
  kill a wedged report export; host-info/report shims time out instead of
  wedging the app; a broken report export reports its error instead of
  pointing at a blank "successful" report.
- Hardening: the file-open bridge only opens non-executable toolkit outputs
  under C:\PreWipeOutput (the app runs elevated).
- Polish: checkbox selections survive a run, export filenames use local time,
  guidance strings no longer reference console-only menu keys.

**The one-line summary for techs: expect more yellow and red on machines that
used to be all green. Those warnings were always true — they were just
invisible. A WARN/FAIL on first run after upgrading is the fix working, not
the toolkit breaking.**

### Behavior changes techs will notice

- **OneDrive sync check is now strict.** A profile is only "safe to wipe"
  when a signed-in account has completed its first sync AND OneDrive.exe is
  running. If OneDrive isn't running when you run the check, you'll get a
  warning telling you to start it — previously this check could not fail,
  even with gigabytes of pending uploads.
- **BitLocker escrow is join-aware.** Entra-joined devices escrow to Entra ID
  (failures are blocking). On-prem-AD devices escrow to Active Directory.
  Workgroup devices get the recovery password captured to
  `C:\PreWipeOutput\BitLockerRecoveryKeys\` and a WARN telling you to move
  that file to secure storage before wiping — it is the only copy.
- **Downloads auto-backup caps at 20 GB.** Bigger folders show a WARN with a
  back-up-manually instruction instead of silently doubling disk usage.
- **Wi-Fi profile export is verified.** Failed exports now show as WARN
  (some) or FAIL (all) instead of always passing. Exported XMLs still contain
  cleartext PSK passwords — the folder is now ACL-restricted to
  Administrators, but still move or delete it after restoring.
- **Unbacked-data scan sees hidden folders now** (including AppData PSTs).
  Loose `.db`/`.sqlite` matches are review-level warnings; QuickBooks and
  Access files remain blocking.
- **BIOS/driver updates report honestly.** Dell exit code 1 (reboot
  required) is success + reboot warning; exit code 2 (unknown error) is a
  failure — these were reversed. BIOS flashes auto-suspend BitLocker so the
  next boot doesn't land on the recovery prompt.
- **The pre-wipe summary fails closed.** Corrupt or missing step output, a
  failed Autopilot registration, or an unverified escrow now block READY TO
  WIPE. Stale (>24 h) results show as a warning without corrupting the
  verdict.
- **TPM warnings surface.** A TPM 2.0 that isn't ready, or an
  Infineon/STMicro/Nuvoton TPM with known Autopilot attestation issues, now
  shows READY WITH WARNINGS instead of a silent green.
- **Autopilot registration no longer waits for profile assignment in batch
  runs** (it could poll Intune forever). Batch runs register and tell you to
  verify assignment in Intune; running the step individually still waits.
- **Faster Full Prep:** the 2-second pause between steps is now 0.5 s
  (saves ~40 s per full run).

### Security

- `C:\PreWipeOutput` is now ACL-restricted to SYSTEM + Administrators (it
  holds Wi-Fi PSKs and captured recovery keys).
- The Dell Command Update installer's Authenticode signature is verified as
  Dell-signed before elevated execution.
- The report HTML no longer has an attribute-injection path, and its
  "Ready to Wipe" banner accounts for prior-session failures.

### For script authors

- Windows PowerShell 5.1 compatibility is enforced: every `.ps1` carries a
  UTF-8 BOM and must pass `Tests\Test-Ps51Compat.ps1` (runs in CI).
- Report JSON filenames follow `Logs\<Script-BaseName>-Report.json`.
- New step scripts need a verdict mapping case in `Get-StepVerdictFromData`
  (`Toolkit-Report.ps1`) — unmapped scripts show WARN, never PASS.
- Run `Tests\Invoke-ToolkitSelfTest.ps1` on a Windows device (add
  `-IncludeReadOnlySteps` in an elevated prompt) before first field use of
  a new build.

### Known limitations

- Steps run in-process, not as child processes: a step that calls
  `[Environment]::Exit()` will terminate the whole toolkit.
- `reagentc`/`cmdkey` text parsing prefers en-US Windows; WinRE has a
  locale-independent ReAgent.xml fallback, credential enumeration does not.
