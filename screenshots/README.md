# Lab M5.02 - Terraform CI/CD Pipeline

## Architecture

```
Pull Request ──► CI Workflow ──► fmt + validate + plan ──► PR Comment
                                                              │
Merge to main ──► CD Workflow ──► init + apply ───────────► AWS
                      │
              [production environment]
              [required reviewer approval]
```

## Infrastructure
- **VPC:** 10.1.0.0/16 with DNS support
- **Public Subnets:** 2 (across 2 AZs)
- **Private Subnets:** 2 (across 2 AZs)
- **Internet Gateway** with public route table
- **State Backend:** S3 + DynamoDB locking

## Workflows
| Workflow | Trigger | Steps |
|----------|---------|-------|
| CI (`ci.yml`) | Pull request to main | fmt, validate, plan, PR comment |
| CD (`cd.yml`) | Push to main | init, apply |

## Secrets Required
| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
```

```bash
git add README.md
git commit -m "Lab M5.02: Add README"
git push origin main
```

---

## Full Summary of Fixes vs. Original

| # | Issue in original | Fix applied |
|---|---|---|
| 1 | `hashicorp/setup-terraform@v3` GPG key expiry breaks `terraform init` | Replaced with direct binary download (same fix as M5.01) |
| 2 | `steps.plan.outputs.stdout` is empty without the setup-terraform wrapper — PR comment posts blank plan | Piped plan to `plan_output.txt`, read file in GitHub Script step |
| 3 | `.terraform.lock.hcl` in `.gitignore` | Removed — lock file should be committed |
| 4 | `gh api repos/{owner}/{repo}/environments/production` uses literal placeholder text | Documented that you must replace with your actual username and repo name |
| 5 | CD workflow ran `terraform plan` as a standalone step before apply — redundant | Removed the standalone plan step; apply handles its own plan internally |