# Linux ↔ Mac Handoff — Account & Money-Safety Checklist
*Created 2026-05-10. Audit BEFORE the first real write to the bucket.*

## What's been verified so far (✓)

- **GitHub repo `keivanmalhani/claude_code_machine_handoff`** — exists, `PRIVATE`, default branch not yet pushed. Private status confirmed via `gh repo view`. ✓
- **R2 free tier activated** — purchase complete confirmed via screenshot. Free tier: 10 GB storage, 1M Class A ops/month, 10M Class B ops/month, **zero egress fees forever**. Overage (only matters if we exceed free tier): $0.015/GB-month storage, $4.50/M Class A, $0.36/M Class B. ✓
- **Bucket `claude-code-handoff`** exists at `https://5b5fa01745f3e206fae845b760f67aff.r2.cloudflarestorage.com/claude-code-handoff`. The S3 endpoint format is correct. ✓

## What still needs verification (audit BEFORE any first-real-write)

### Bucket-level settings (Cloudflare → R2 → claude-code-handoff → Settings)

| Setting | Safe value | Dangerous value | Why |
|---|---|---|---|
| Public access | **OFF** (R2.dev subdomain disabled) | ON | Public access = anyone with the URL can read every file. We don't need public access since the handoff is between two of YOUR machines via API token. |
| Custom domain | not configured | configured + public | Same as above — only enable if there's a reason. |
| CORS policy | empty | wildcard `*` | Empty is safest. We'll only access from CLI tools that don't need CORS. |
| Lifecycle rules | none, OR delete-after-N-days for old snapshots | aggressive auto-delete on everything | Optional — could set to delete snapshots > 90 days old to keep storage low. |
| Event notifications | none | configured to trigger Workers | These cost extra. Don't enable. |
| Object Lock | OFF | ON | Object lock = files become immutable, complicates testing. |

### API token scoping (Cloudflare → R2 → Manage R2 API Tokens → Create token)

| Setting | Safe value | Dangerous value | Why |
|---|---|---|---|
| Token name | `claude-code-handoff-rw` | (anything generic) | Naming-for-purpose makes it auditable later. |
| Permissions | **Object Read & Write** | Admin Read & Write | We don't need admin (which can create/delete buckets). RW on objects is enough. |
| Specify bucket | **Apply to specific buckets only → claude-code-handoff** | All buckets | Least-privilege. If this token leaks, only this one bucket is at risk. |
| TTL | None (or 1 year if you prefer) | Forever-with-no-rotation | TTL is fine for this use case. If you set it, mark a calendar reminder to rotate. |

After creating: **save the access key ID + secret access key** (Cloudflare only shows the secret once). Paste them back in chat — I'll write them to `/home/keivanm/Documents/autobot-vault/accounts/cloudflare-r2.env` with `chmod 600`.

### Account-level billing safeguards (Cloudflare → Billing)

| Setting | Safe value | Dangerous value | Why |
|---|---|---|---|
| Plan | **Free** | Workers Paid plan, Pro, etc. | We only need free plan for R2 + Pages. Don't accidentally upgrade. |
| Notifications | **Enable "Bill above $X" alert** for X = $1 | Disabled | If we ever generate a bill, you find out fast. Set X = $1 because the bill should be $0 with current usage. |
| Payment method | Already on file (since you activated R2) | — | Verify it's a card you watch, not one buried somewhere. |

## Cloudflare Pages — still to do

This is the cloud-hosted dashboard mirror (so you can see your dashboard from anywhere even when both Linux and Mac are off).

- **Cloudflare → Workers & Pages → Create → Pages → Connect to Git**
- Authorize Cloudflare to access your GitHub
- Connect to the `keivanmalhani/claude_code_machine_handoff` repo (Pages will deploy from a `dashboard/` subdirectory or from `main` branch — I'll configure that once the connection exists)
- Project name: `claude-code-handoff-dashboard` (or whatever you prefer)
- Free plan: 500 builds/month, unlimited bandwidth, unlimited requests. Won't ever bill.

## When to use this checklist

Before pushing the first 100MB to the bucket. Before flipping any "go live" switch on a `/switch-to-mac` command. Before you walk away from the box and leave the handoff system running unattended. Re-audit if anything in the Cloudflare dashboard changes.
