# Lab M5.02 — Terraform CI/CD Pipeline (Corrected)

> **What changed from the original and why** is noted in `> blockquotes` throughout.

---

## Summary of All Issues Found

| # | Issue | Severity | Impact |
|---|-------|----------|--------|
| 1 | GPG key expiry — same as M5.01, `hashicorp/setup-terraform@v3` fails on `terraform init` | 🔴 Critical | Both CI and CD break at init |
| 2 | `terraform plan` stdout not captured — `steps.plan.outputs.stdout` is empty unless `terraform_wrapper: true` is set | 🔴 Critical | PR comment posts a blank plan |
| 3 | `.terraform.lock.hcl` in `.gitignore` — lock file should be committed | 🟡 Medium | CI may use different provider versions than local |
| 4 | `gh api` environment command is wrong syntax — uses `{owner}/{repo}` literally instead of real values | 🟡 Medium | CLI command fails |
| 5 | S3 backend bucket creation missing `--create-bucket-configuration` for regions other than `us-east-1` | 🟡 Medium | Fails if student is not in us-east-1 (lab uses us-east-1 so low risk, but worth noting) |
| 6 | No `terraform.tfvars` content provided — file is created with `touch` but never populated | 🟢 Low | Not strictly needed since variables have defaults, but confusing |
| 7 | CD workflow runs `terraform plan` twice (once standalone, once before apply) — redundant and doubles runtime | 🟢 Low | Wastes time, not a blocker |

---

## Prerequisites

- Completed Lab M5.01
- AWS credentials configured as repository secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- GitHub CLI authenticated — run `gh auth login` if not done yet
- AWS CLI installed and configured locally (needed for Step 2 to create the S3 backend)

---

## Step 1: Create the Project Structure

```bash
mkdir -p ~/ce-labs/m5-02-cicd/.github/workflows
cd ~/ce-labs/m5-02-cicd

touch main.tf variables.tf outputs.tf backend.tf .gitignore
```

Add `.gitignore`:

```
.terraform/
*.tfstate
*.tfstate.backup
*.tfplan
```

> **Fix:** Removed `.terraform.lock.hcl` from `.gitignore` — same issue as M5.01. The lock file must be committed so CI uses identical provider versions to your local machine.

---

## Step 2: Create the S3 Backend Resources

Run these once from your terminal. Replace `YOURNAME` with something unique (e.g. your GitHub username).

```bash
# Create the state bucket
aws s3api create-bucket \
  --bucket ce-bootcamp-tfstate-YOURNAME \
  --region us-east-1

# Enable versioning on the bucket
aws s3api put-bucket-versioning \
  --bucket ce-bootcamp-tfstate-YOURNAME \
  --versioning-configuration Status=Enabled

# Create the DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Verify the bucket exists before moving on:

```bash
aws s3 ls | grep ce-bootcamp-tfstate
```

---

## Step 3: Write the Terraform Configuration

### `backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket         = "ce-bootcamp-tfstate-YOURNAME"
    key            = "m5-02-cicd/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

Replace `YOURNAME` with the same value you used in Step 2.

### `variables.tf`

```hcl
variable "project_name" {
  description = "Project identifier"
  type        = string
  default     = "cicd-lab"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.11.0/24", "10.1.12.0/24"]
}
```

### `main.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "terraform"
    Pipeline    = "github-actions"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    Tier = "Public"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    Tier = "Private"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

### `outputs.tf`

```hcl
output "vpc_id" {
  description = "VPC identifier"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet identifiers"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet identifiers"
  value       = aws_subnet.private[*].id
}
```

---

## Step 4: Build the CI Workflow

Create `.github/workflows/ci.yml`:

```yaml
name: Terraform CI

on:
  pull_request:
    branches:
      - main

permissions:
  contents: read
  pull-requests: write

env:
  AWS_REGION: "us-east-1"

jobs:
  terraform-ci:
    name: Format · Validate · Plan
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install Terraform
        run: |
          wget -O terraform.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
          unzip terraform.zip
          sudo mv terraform /usr/local/bin/
          terraform version

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive

      - name: Terraform Init
        id: init
        run: terraform init
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

      - name: Terraform Validate
        id: validate
        run: terraform validate -no-color

      - name: Terraform Plan
        id: plan
        run: |
          terraform plan -input=false -no-color 2>&1 | tee plan_output.txt
          echo "PLAN_EXIT_CODE=${PIPESTATUS[0]}" >> $GITHUB_ENV
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

      - name: Post Plan to PR
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        with:
          script: |
            const fs = require('fs');
            let plan = fs.readFileSync('plan_output.txt', 'utf8');
            if (plan.length > 60000) {
              plan = plan.substring(0, 60000) + "\n\n... (truncated)";
            }

            const body = `### Terraform Plan Result
            \`\`\`
            ${plan}
            \`\`\`
            *Pushed by @${{ github.actor }} · Workflow: \`${{ github.workflow }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: body
            });
```

> **Fix 1 (Critical):** Replaced `hashicorp/setup-terraform@v3` with the direct binary download — same GPG key expiry fix from M5.01. Without this, `terraform init` fails immediately.

> **Fix 2 (Critical):** The original used `${{ steps.plan.outputs.stdout }}` to capture the plan output. This only works when `hashicorp/setup-terraform` is used with its built-in wrapper. Since we install Terraform directly, `steps.plan.outputs.stdout` is always empty — the PR comment would post a blank plan. The fix pipes plan output to a file (`tee plan_output.txt`) and reads that file in the GitHub Script step instead.

---

## Step 5: Build the CD Workflow

Create `.github/workflows/cd.yml`:

```yaml
name: Terraform CD

on:
  push:
    branches:
      - main

permissions:
  contents: read

env:
  AWS_REGION: "us-east-1"

jobs:
  terraform-apply:
    name: Deploy Infrastructure
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install Terraform
        run: |
          wget -O terraform.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
          unzip terraform.zip
          sudo mv terraform /usr/local/bin/
          terraform version

      - name: Terraform Init
        run: terraform init
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

      - name: Terraform Apply
        run: terraform apply -auto-approve -input=false -no-color
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

> **Fix 3:** Removed the redundant standalone `terraform plan` step from the CD workflow. The original ran plan twice — once on its own, then implicitly again inside apply. This doubles runtime for no benefit. Apply always runs its own plan internally before making changes.

---

## Step 6: Initialize the Repo and Push

```bash
cd ~/ce-labs/m5-02-cicd
git init
git add .
git commit -m "Initial commit: VPC config with CI/CD pipelines"

gh repo create ce-lab-terraform-cicd-pipeline --public --source=. --push
```

Set repository secrets (your AWS credentials must already be set as shell environment variables):

```bash
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
```

Verify secrets are set:

```bash
gh secret list
```

The initial push to `main` will trigger the **CD workflow**. Go to the **Actions** tab and watch it run — it will do the first `terraform apply` and create your VPC in AWS.

---

## Step 7: Configure the GitHub Environment

Go to your repository on GitHub:

1. **Settings → Environments → New environment**
2. Name it `production`
3. Enable **Required reviewers** — add yourself
4. Click **Save protection rules**

If you prefer the CLI, use your actual GitHub username and repo name:

```bash
gh api repos/YOUR_GITHUB_USERNAME/ce-lab-terraform-cicd-pipeline/environments/production \
  --method PUT \
  --field wait_timer=5
```

> **Fix 4:** The original showed `{owner}/{repo}` literally in the command. That is placeholder text — the CLI does not expand it automatically. You must replace it with your actual GitHub username and repo name.

---

## Step 8: Test the Full CI/CD Flow

Create a feature branch:

```bash
git checkout -b feature/add-cost-center-tag
```

Edit the VPC resource in `main.tf` — add a `CostCenter` tag:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "terraform"
    Pipeline    = "github-actions"
    CostCenter  = "engineering"
  }
}
```

Commit, push, and open a PR:

```bash
git add .
git commit -m "Add CostCenter tag to VPC"
git push -u origin feature/add-cost-center-tag

gh pr create \
  --title "Add CostCenter tag to VPC" \
  --body "Adds cost allocation tag to the VPC resource for FinOps tracking."
```

**What to observe:**

1. Go to **Actions** tab → CI workflow runs on the PR
2. When it finishes, go to the **Pull Requests** tab → open the PR → scroll down to see the plan posted as a comment
3. The plan should show `~ update in-place` for the VPC (adding the tag)
4. Merge the PR: `gh pr merge --squash`
5. Go back to **Actions** — the CD workflow triggers and applies the change
6. If you set required reviewers on the `production` environment, you'll need to approve the deployment first

---

## Step 9: Write the README and Submit

```bash
git checkout main
git pull origin main
```

Create `README.md`:

```markdown
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
