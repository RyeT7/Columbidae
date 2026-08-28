Download the `columbidae-<version>.zip` asset below, extract it on the deploy VM,
and follow **Setup** in the README.

**Fresh install**

1. Extract the folder somewhere on the VM (e.g. `C:\deploy`).
2. Copy `config.example.yaml` to `config.yaml` and edit it.
3. Run `.\deploy-poll-lite.ps1` once by hand to confirm it works.
4. From an elevated prompt, run `.\install-task.ps1` to register the scheduled task.

**Upgrade**

1. Disable the scheduled task, so a deploy cannot be running while files are replaced.
2. Extract this release over the existing folder.
3. Re-enable the task. Re-run `install-task.ps1` only if `poll_interval_minutes` changed.

Your `config.yaml` is never touched by an upgrade -- the release deliberately ships
`config.example.yaml` instead, so an extract-over-the-top cannot destroy the
`github_token` and `webhook_url` on a live target.

**Before running any of it**, check the download against the published `.sha256`:

```powershell
Get-FileHash .\columbidae-<version>.zip -Algorithm SHA256
```

The scheduled task runs this code as SYSTEM on a machine that matters. Verify it.
