# Columbidae

Pull-based IIS deployment for a Windows VM that cannot host a CI agent.

[![Tests](https://github.com/RyeT7/Columbidae/actions/workflows/tests.yml/badge.svg)](https://github.com/RyeT7/Columbidae/actions/workflows/tests.yml)

A stateless PowerShell script, fired by Task Scheduler every few minutes, that
pulls the latest build from GitHub Releases, swaps it into IIS, health-checks
it, and rolls back automatically if the site doesn't come up. It leaves nothing
running between deploys.

> **Note:** this repo contains the *deploy pipeline only*. The application it
> deploys lives in its own repository — see [Setup](#setup).

---

## Why not Jenkins or a self-hosted runner?

The design targets a shared, memory-constrained production Windows host that
accepts no inbound connections from outside its network. Two constraints follow:

- **No persistent process may run on the target.** A long-lived agent that can
  grow in memory over time isn't an acceptable risk on a shared production
  host. That rules out Jenkins, and also a self-hosted GitHub Actions runner —
  lightweight, but still permanently resident.
- **Nothing may connect *inward*.** Outbound is fine; inbound is not available.

So nothing pushes to the target. It pulls, on its own schedule, and exits.
Builds happen on GitHub's free hosted runners; the target only ever downloads an
artifact and copies files. **It never compiles anything, and never touches other
services on the host.**

## How it works

```mermaid
flowchart LR
    subgraph APP["Application repo"]
        direction TB
        A["push to main"]
        B["GitHub Actions<br>hosted runner, ephemeral<br>dotnet publish, zip"]
        A --> B
    end

    subgraph GH["GitHub Releases"]
        C["deploy-SHA, marked latest<br>release.zip"]
    end

    subgraph TARGET["Deploy target"]
        direction TB
        D["Task Scheduler<br>every 2-5 min"]
        E["deploy-poll-lite.ps1"]
        F["download, extract<br>repoint IIS path<br>health check<br>rollback or record<br>exit"]
        D --> E --> F
    end

    B -->|"publishes, outbound"| C
    E -.->|"polls, outbound"| C
```

Note the direction of both arrows: they *originate* from the app runner and from
the deploy target. Neither side ever connects to the other, and nothing ever
connects inward — GitHub is a durable hand-off point that both sides reach out
to.

Each deploy extracts into a fresh `release-<timestamp>` folder and repoints the
IIS site's physical path at it. Rollback is therefore just pointing the path
back at the previous folder — no re-download, no partial state.

## What's in this repo

| Path | Purpose |
|---|---|
| `deploy-poll-lite.ps1` | Entry point. The only thing Task Scheduler invokes. Orchestration only. |
| `lib\*.ps1` | The work, split by concern: `Logging`, `Config`, `Lock`, `GitHub`, `Iis`, `Releases`. Dot-sourced, never `Import-Module`. |
| `config.yaml` | All per-deployment settings. Reconfigure here, not in the script. |
| `tests\run-tests.ps1` | Unit tests for config parsing, the overlap guard, and release pruning. No Pester required. |
| `examples\deploy-release.yml` | **Template** for the *app repo's* build workflow. Not run from this repo. |

## Setup

### 1. In the application's repository

Copy [`examples/deploy-release.yml`](examples/deploy-release.yml) to
`.github/workflows/` there and set `PROJECT_PATH` to the real `.csproj`.

Four things must match the VM's `config.yaml` or the poller silently never
deploys:

| Requirement | Why |
|---|---|
| Asset named `release.zip` | Must equal `release_asset_name` |
| Release marked `--latest` | The poller reads `/releases/latest` |
| Tag `deploy-<sha>` | Compared against the recorded state to detect "new" |
| Archive root **is** the web root | IIS points straight at the extracted folder |

That last one is the easy mistake: zip the *contents* of the publish output
(`cd publish && zip -r ../release.zip .`), not the folder. Nesting it one level
down means IIS finds no `web.config`, the health check fails, and the deploy
rolls back.

### 2. On the deploy VM

Copy **the whole folder** — the script needs `lib\` and `config.yaml` beside
it. It verifies the full lib set at startup and exits `2` before touching IIS
if anything is missing, but don't rely on that; copy it as a unit.

Then edit `config.yaml`:

```yaml
github_owner: <your-org>
github_repo: <app-repo-name>
iis_site_name: <IIS site name>
health_url: http://localhost/health
deploy_root: C:\inetpub\deployments\<app>
```

Run it once by hand to confirm it works before scheduling it.

### 3. Register the scheduled task

```
schtasks /create /tn "Columbidae Deploy Poll" /sc minute /mo 3 /ru SYSTEM ^
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\deploy\deploy-poll-lite.ps1\""
```

⚠️ Then open the task's **Settings** tab and tick **"If the task is already
running, do not start a new instance."** `schtasks` cannot set this from the
command line. It's a second line of defense alongside the script's own lock
file, not a replacement for it.

Keep the interval longer than a worst-case run (download + extract + health
retries), or most polls just hit the overlap guard and skip — harmless, but
noisy in the log.

## Multiple apps in one site

A frontend at `/` and a backend at `/api` under the same IIS site deploy
independently. Give each its own config file and its own scheduled task —
the script itself stays generic.

```yaml
# frontend.yaml                    # backend.yaml
iis_site_name: My Site             iis_site_name: My Site
iis_app_path: /                    iis_app_path: /api
health_url: http://localhost/      health_url: http://localhost/api/health
deploy_root: C:\deploy\web         deploy_root: C:\deploy\api
release_asset_name: web.zip        release_asset_name: api.zip
```

```powershell
.\deploy-poll-lite.ps1 -ConfigPath C:\deploy\frontend.yaml
.\deploy-poll-lite.ps1 -ConfigPath C:\deploy\backend.yaml
```

⚠️ **`deploy_root`, `lock_file`, and `state_file` must differ between configs.**
Sharing a lock file makes each run block the other; sharing a state file makes
each one think the other's release is already deployed. The defaults derive from
`deploy_root`, so giving each config a distinct `deploy_root` is enough.

Because repointing a sub-application only recycles that application's pool,
deploying the backend doesn't cold-start the frontend.

**Publishing the two artifacts** — pick one:

| Approach | How it works |
|---|---|
| One repo, one release, two assets | CI attaches `web.zip` and `api.zip` to the same release. Both configs poll the same tag and pick their own asset. Simplest, and keeps the two in lockstep. |
| Two repos | Each has its own workflow, releases, and tags. Fully independent lifecycles. Best if the two ship on different cadences. |

## Configuration

| Key | Default | Notes |
|---|---|---|
| `github_owner` | — | **Required.** |
| `github_repo` | — | **Required.** The *app's* repo. |
| `release_asset_name` | `release.zip` | Must match what CI attaches. |
| `github_token` | *(blank)* | Only for private repos. See [Limitations](#limitations). |
| `iis_site_name` | — | **Required.** |
| `iis_app_path` | `/` | Which app in the site to repoint. `/` = site root, `/api` = sub-application. |
| `health_url` | — | **Required.** Must return 200 only when genuinely ready. |
| `deploy_root` | — | **Required.** Same volume as the site. |
| `log_file` / `lock_file` / `state_file` | under `deploy_root` | |
| `log_max_size_mb` | `5` | Rotate past this size. `0` disables rotation. |
| `log_keep` | `3` | Archives kept. Disk ceiling is `(log_keep + 1) × log_max_size_mb`. |
| `health_retries` | `10` | |
| `health_retry_delay_seconds` | `3` | `retries × delay` must exceed cold-start time. |
| `keep_releases` | `5` | Live and previous release are never pruned. |
| `lock_stale_minutes` | `30` | Locks older than this are treated as abandoned. |
| `webhook_url` | *(blank)* | Blank disables notifications. **A credential — never commit a real one.** |
| `webhook_timeout_seconds` | `10` | Kept short so a hung endpoint can't hold the lock. |
| `http_timeout_seconds` | `120` | |

The parser is a deliberately minimal flat `key: value` reader — no nesting, no
lists — so the VM needs no third-party YAML module.

> **`health_url` is the single most important setting.** The rollback decision
> depends entirely on it being honest about readiness. An endpoint that returns
> 200 before the app can serve traffic will let broken deploys through.

## Operating it

Status lives in `deploy.log` under `deploy_root`. There is no dashboard and no
notifications yet.

```powershell
Get-Content C:\inetpub\deployments\<app>\deploy.log -Tail 40 -Wait
```

Routine polls that find nothing new are intentionally **not** logged — at a
3-minute interval that would bury everything that matters. A quiet day writes
nothing at all.

**Disk usage is bounded.** `deploy.log` rotates to `deploy.log.1`, `.2`, … once
it passes `log_max_size_mb`, and the oldest is dropped. The ceiling is
`(log_keep + 1) × log_max_size_mb` — **20 MB** with the defaults, and only
reached if something is failing on every tick. Set `log_max_size_mb: 0` to
disable rotation.

Rotation runs inline during a normal deploy run, not from any background
process — nothing is left resident to do housekeeping. A rotation failure is
logged and ignored rather than failing the deploy.

> Releases, not logs, are the larger consumer: `keep_releases × published size`
> under `deploy_root`. A 200 MB app with the default `keep_releases: 5` holds
> about 1 GB. Lower it if the host is tight on storage.

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | Nothing to do, or deploy succeeded |
| `1` | Deploy failed, site was rolled back |
| `2` | Couldn't start: incomplete install, bad config, IIS unavailable, GitHub unreachable |

**Force a redeploy** of the current release:

```powershell
.\deploy-poll-lite.ps1 -Force
```

**When a health check fails**, the script repoints IIS at the previous release
and re-checks it. The state file is deliberately left untouched, so the next
tick retries the same tag rather than marking a failed release as deployed.
If rollback *also* fails to restore health, the log says so explicitly and the
site needs manual attention.

**To verify the memory-safety property** this design exists for: watch
`Get-Process powershell` during a manual run. It should spike briefly during
`Expand-Archive` and drop to nothing the instant the script exits.

## Notifications

Optional. Set `webhook_url` to enable; leave it blank and nothing is sent.

```yaml
webhook_url: https://your-endpoint.example.com/deploy-events
webhook_timeout_seconds: 10
```

Notifications fire on **deploy success**, **rollback**, **failed rollback**, and
**fatal errors** — never on routine polls that find nothing new, which at a
3-minute interval would be pure noise.

A single platform-neutral JSON event is POSTed:

```json
{
  "status":    "rolled-back",
  "tag":       "deploy-a1b2c3d",
  "target":    "My Site/api",
  "message":   "Health check failed after 10 attempts. Rolled back...",
  "host":      "WEBVM01",
  "timestamp": "2026-08-26T14:22:30Z"
}
```

`status` is one of `success`, `rolled-back`, `rollback-failed`, or `error`.
`tag` and `target` may be empty if the run failed before determining them.

**Chat platforms are deliberately not built in.** Reshaping an event into a
Slack or Teams message is a consumer's job — putting that in the deploy path
would mean the pipeline carrying platform-specific knowledge it has no reason
to hold. Point `webhook_url` at anything that speaks HTTP and translate there.
There is exactly one payload shape, and no format switch to configure.

Treat the field names as a contract: adding fields is safe, renaming or
removing them is not. The test suite asserts the exact schema so a break is
loud rather than silent.

Two guarantees worth knowing:

- **A broken webhook never breaks a deploy.** Every send is wrapped and
  downgraded to a `WARN` in the log. An unreachable endpoint is a non-event.
- **Every send has a hard timeout.** `Invoke-RestMethod` defaults to *waiting
  indefinitely*; an endpoint that accepts the connection but never replies
  would otherwise hold the deploy lock until the stale-lock threshold broke it.

> ⚠️ A webhook URL is a credential — anyone holding it can post events to your
> endpoint. Set it only in the copy of `config.yaml` on the deploy target, never
> in a committed one. The same applies to `github_token`.

## Testing

```powershell
.\tests\run-tests.ps1
```

Covers config parsing, the overlap guard, and release pruning — everything that
needs no GitHub, IIS, or network. Exits non-zero on failure. Run it on a dev
machine, not the VM.

`lib\Iis.ps1` and `lib\GitHub.ps1` require real IIS and a real network, so CI
only syntax-checks them.

## Requirements

- Windows PowerShell 5.1 (CI pins to this, not PowerShell 7)
- IIS with the `WebAdministration` module (IIS management tools)
- Permission to modify the target site's configuration
- Outbound HTTPS to `github.com` and `api.github.com`

## Limitations

Known and deliberate:

- **No approval gate.** This is continuous *deployment* — every release ships
  automatically. Publishing releases as prereleases and promoting them by hand
  gates this without any script change, since `/releases/latest` ignores
  prereleases.
- **One deploy target per config.** Each `config.yaml` drives exactly one IIS
  application. Deploying more — including a frontend and backend sharing one
  site — means one config file and one scheduled task each, never a fork of the
  script. See [Multiple apps in one site](#multiple-apps-in-one-site).
- **No cross-app coordination.** Targets deploy and roll back independently, so
  a backend that fails its health check rolls back while the frontend stays on
  the new release. If a change spans both, they can be briefly mismatched.
- **Private repo support is unverified.** The code path is written and handles
  the S3 redirect correctly, but has never been run against a real private repo.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for the full text.

Copyright 2026 Ryuu Stanley Tistogondo
