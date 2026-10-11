# Best Egg mini project: the CSV pipeline

A small, real version of the scenario Steve asked about in the interview, built the way his team works.

> People drop CSV files into S3. Good rows go to a database, bad rows are kept, and an email says it's done.

```
S3 (incoming/) ──event──> SQS ──> Lambda ──> DynamoDB        good rows
                           │         ├────> S3 rejected/     bad rows, kept for audit
                           │         └────> SNS email        "2 rows saved, 3 rows rejected"
                           └── after 3 failed tries ──> dead-letter queue ──> alarm email
```

## Why this matches Best Egg

| What Best Egg told you | Where it is in this project |
|---|---|
| 40% serverless, mostly Lambda triggered by **SQS** and **S3** | The whole pipeline: S3 event → SQS → Lambda |
| **Terraform** for the foundations | `bootstrap/` and `infra/` |
| Terraform Cloud is **expensive** | State lives in **S3 with locking** instead |
| Barclays: **every change gated by a pull request** | GitHub Actions: tests, security scan and a plan on every pull request |
| Barclays: **no manual changes**, approvals, auditing | Changes only go out after a human approves |
| Security and auditability | KMS encryption everywhere, least-privilege IAM, rejected rows kept |
| On-call and the support rotation | Alarms by email, and a step where you break it on purpose |

## The whole thing at a glance

| Part | What you do | Time |
|---|---|---|
| 1. Accounts and tools | AWS account, budget alert, a user for the command line, install tools, connect AWS and GitHub | 45 min |
| 2. Get the project and test it | Unzip it, run the tests on your computer | 10 min |
| 3. Build it in AWS | Bootstrap, deploy, send a file through, break it on purpose | 1 hour, plus 30 min of waiting |
| 4. Change control | GitHub repo, settings, approval step, push, make a change by pull request | 1 hour |
| 5. Tear it down | Remove everything so it stops costing money | 10 min |

**Cost:** about $1 a month, almost all of it the encryption key. Tear it down when you're done.

**Your computer:** the commands are for **Ubuntu Linux**. **Mac** notes are included where the commands differ. On **Windows**, install WSL first: open PowerShell as administrator, run `wsl --install`, restart, then open **Ubuntu** from the Start menu and use the Ubuntu commands.

It's been tested here, but your run is the first one in a real AWS account. If a step fails, see **If something goes wrong** near the end.

---

# Part 1 — Accounts and tools (once)

### Step 1. AWS account

1. Sign in at **aws.amazon.com**, or create an account.
2. Protect the root login: click your account name (top right) → **Security credentials** → **Assign MFA device**. Use an authenticator app.

### Step 2. Budget alert

**Billing and Cost Management → Budgets → Create budget → Use a template → Monthly cost budget.** Set **$5** and your email. You'll get an email if anything costs more than expected.

### Step 3. A user for the command line

You shouldn't use the root login for day-to-day work.

1. **IAM → Users → Create user.** Name it `terraform-admin`.
2. **Attach policies directly** → tick **AdministratorAccess** → **Create user**.
3. Open the user → **Security credentials** → **Create access key** → choose **Command Line Interface (CLI)** → tick the confirmation → **Create**.
4. **Copy both keys now.** The secret is only shown once.

### Step 4. Install the tools

```bash
sudo apt update
sudo apt install -y curl wget unzip git gnupg lsb-release python3 python3-venv gh

# AWS CLI (on an ARM computer, use awscli-exe-linux-aarch64.zip)
cd ~
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install   # if it says it's already installed, add --update

# Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

**Mac:** install Homebrew from **brew.sh**, then `brew install awscli gh python git` and `brew install hashicorp/tap/terraform`.

Check them:

```bash
aws --version
terraform version   # needs 1.10 or newer
```

### Step 5. Connect the AWS CLI

```bash
aws configure
```

Paste the two keys from Step 3. Region: `us-east-1`. Output format: `json`.

```bash
aws sts get-caller-identity
```

You should see your account number and `terraform-admin`.

### Step 6. GitHub

1. Create a free account at **github.com** if you don't have one.
2. Connect git to it:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
gh auth login -s workflow
```

Choose **GitHub.com → HTTPS → Yes (authenticate Git) → Login with a web browser**, and follow the prompts. The `-s workflow` part lets you push the pipeline file.

Your commit email shows on a public repo. To keep yours private, use the `@users.noreply.github.com` address GitHub gives you under **Settings → Emails**.

---

# Part 2 — Get the project and test it

### Step 7. Unzip it

```bash
cd ~
unzip ~/Downloads/bestegg-csv-pipeline.zip
cd ~/bestegg-csv-pipeline
```

If your download is somewhere else, change the path. If your Mac already unzipped it, run `mv ~/Downloads/bestegg-csv-pipeline ~/` instead of the unzip line. On Windows (WSL), your Downloads folder is `/mnt/c/Users/YOUR-WINDOWS-NAME/Downloads`.

### Step 8. Run the tests

The tests fake AWS on your computer, so this is free.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r lambda/requirements-dev.txt
pytest -q lambda
```

You should see `4 passed`: good rows saved, bad rows rejected, no duplicates when run twice, and failures reported for retry.

---

# Part 3 — Build it in AWS

### Step 9. Bootstrap (once)

This creates what Terraform needs before it can run: the state bucket, and the roles GitHub will use.

```bash
cd ~/bestegg-csv-pipeline/bootstrap
terraform init
terraform apply -var 'github_repo=YOUR-GITHUB-USERNAME/bestegg-csv-pipeline'
```

Spell your GitHub username exactly as GitHub shows it, capital letters included. Type `yes`.

Save the three outputs: `state_bucket`, `plan_role_arn`, `apply_role_arn`. You can see them again any time with `terraform output` in this folder.

Don't delete the `terraform.tfstate` file in this folder. You'll need it to remove these later.

### Step 10. Deploy the pipeline

```bash
cd ~/bestegg-csv-pipeline/infra
terraform init -backend-config="bucket=YOUR-STATE-BUCKET"
terraform apply -var 'notify_email=you@example.com'
```

Type `yes`. It takes a few minutes.

Then **open your email and click "Confirm subscription"** in the message from AWS (check spam too). Without that, no emails arrive.

### Step 11. Try it

Run these from the `infra` folder:

```bash
BUCKET=$(terraform output -raw bucket)
TABLE=$(terraform output -raw table)

aws s3 cp ../sample/customers.csv "s3://$BUCKET/incoming/customers.csv"
```

Within a minute:

- **Email:** "File incoming/customers.csv: 2 rows saved, 3 rows rejected."
- **Database:** `aws dynamodb scan --table-name "$TABLE" --select COUNT` shows `"Count": 2`
- **Rejected rows, with reasons:** `aws s3 cp "s3://$BUCKET/rejected/customers.csv" -`

Upload the same file again. The count stays at 2, because retries are safe.

### Step 12. Break it on purpose

`sample/broken.csv` contains bytes that can't be read as text, so it always fails.

Stay in the `infra` folder. If you opened a new terminal, first run `cd ~/bestegg-csv-pipeline/infra` and `BUCKET=$(terraform output -raw bucket)`.

```bash
aws s3 cp ../sample/broken.csv "s3://$BUCKET/incoming/broken.csv"
```

What happens:

1. The Lambda fails and reports that one message as failed.
2. SQS hides it for 6 minutes, then tries again. This happens 3 times.
3. After the 3rd failure, the message moves to the **dead-letter queue**.
4. The **dlq-not-empty** alarm emails you, usually 20–40 minutes after the upload.

While you wait, read the logs the way you would on call:

```bash
aws logs tail "/aws/lambda/$(terraform output -raw function_name)" --since 30m
```

You'll see `"event": "failed"` with the error.

**Fix and replay.** Put a good file at the same name, then send the stuck message back:

```bash
aws s3 cp ../sample/customers.csv "s3://$BUCKET/incoming/broken.csv"
aws sqs start-message-move-task --source-arn "$(terraform output -raw dead_letter_queue_arn)"
```

The new upload is processed on its own, and the replayed message processes the same file again. Each row is stored under a fixed key, so nothing gets duplicated.

Why the 6-minute wait? The queue's visibility timeout is 6 times the Lambda timeout. If it were shorter, a message could be handed out again while the first attempt was still running.

---

# Part 4 — Change control with GitHub Actions

### Step 13. Create the repo

On **github.com/new**:

- Name: `bestegg-csv-pipeline`
- **Public** — the approval step is only free on public repos, and a public repo is something you can show in interviews
- Don't add a README
- **Create repository**

Plans posted on pull requests will show your AWS account number. That's normal; AWS doesn't treat it as secret. Your email stays hidden.

### Step 14. Add the settings

In the repo: **Settings → Secrets and variables → Actions.**

On the **Variables** tab, click **New repository variable** and add three:

| Name | Value |
|---|---|
| `STATE_BUCKET` | from Step 9 |
| `PLAN_ROLE_ARN` | from Step 9 |
| `APPLY_ROLE_ARN` | from Step 9 |

On the **Secrets** tab, click **New repository secret** and add one:

| Name | Value |
|---|---|
| `NOTIFY_EMAIL` | the same email you used in Step 10 |

It's a secret so it stays hidden in the public logs.

### Step 15. Add the approval step

**Settings → Environments → New environment.** Name it `production` → **Configure environment** → tick **Required reviewers** → add yourself → **Save protection rules**.

Do this before Step 16. If the environment doesn't exist when the pipeline first runs, GitHub creates it with no approval step.

### Step 16. Push the code

```bash
cd ~/bestegg-csv-pipeline
git init
git add .
git commit -m "CSV pipeline"
git branch -M main
git remote add origin https://github.com/YOUR-GITHUB-USERNAME/bestegg-csv-pipeline.git
git push -u origin main
```

Open the **Actions** tab. Tests and the security scan run, then the deploy step waits. Click **Review deployments → production → Approve and deploy**. It finishes with **No changes**, because you already built it in Step 10.

If it shows changes instead, read them before you approve. The usual cause is a different email in the secret than in Step 10.

### Step 17. Make a change the proper way

```bash
git checkout -b alert-sooner
sed -i 's/= 900$/= 600/' infra/main.tf   # files-waiting alarm: 15 minutes -> 10
git diff                                  # check the one-line change
git commit -am "Alert sooner when files are waiting"
git push -u origin alert-sooner
```

**Mac:** use `sed -i ''` instead of `sed -i`. Or open `infra/main.tf`, find the files-waiting alarm, and change its threshold from `900` to `600`.

On GitHub, click **Compare & pull request → Create pull request**. Watch:

1. Tests, formatting and the security scan run.
2. The Terraform plan is posted as a comment: **1 to change**.
3. Click **Merge pull request**.
4. In **Actions**, approve the deploy. The change goes out.

That's the whole Barclays-style flow: reviewed in a pull request, approved by a person, applied by the pipeline, and nobody touched the console.

---

# Part 5 — Tear it down

```bash
cd ~/bestegg-csv-pipeline/infra
terraform destroy -var 'notify_email=you@example.com'
```

Type `yes`. The encryption key stops costing money as soon as it's scheduled for deletion.

**Optional, to remove everything:**

1. **S3 console** → open the `tfstate-...` bucket → **Empty** → confirm.
2. `cd ~/bestegg-csv-pipeline/bootstrap && terraform destroy -var 'github_repo=YOUR-GITHUB-USERNAME/bestegg-csv-pipeline'`
3. **IAM → Users → terraform-admin → Security credentials** → delete the access key.

You can keep the GitHub repo to show people. Just don't approve any new deployments after a teardown, or it will build everything again.

---

## If something goes wrong

**No emails arrive.** Confirm the subscription email from AWS (check spam), then upload a file again.

**Step 9 says the OIDC provider already exists.** Your account already has one for GitHub. Bring it into this project, then run the apply again:

```bash
terraform import -var 'github_repo=YOUR-GITHUB-USERNAME/bestegg-csv-pipeline' aws_iam_openid_connect_provider.github arn:aws:iam::YOUR-ACCOUNT-ID:oidc-provider/token.actions.githubusercontent.com
```

Then in Part 5, run `terraform state rm aws_iam_openid_connect_provider.github` before the bootstrap destroy, so it stays for whatever else uses it.

**`terraform init` can't find the bucket.** Check the name with `terraform output` in the `bootstrap` folder.

**GitHub says "Not authorized to perform sts:AssumeRoleWithWebIdentity".** The repo name from Step 9 has to match GitHub exactly, capital letters included, and the environment must be called `production`. Fix it, then run Step 9's apply again.

**The plan fails with "Invalid value for variable".** The `NOTIFY_EMAIL` secret is missing or isn't an email address (Step 14).

**The Formatting check fails.** Run `terraform fmt -recursive` in the project folder, then commit and push.

**"Error acquiring the state lock".** A run was stopped halfway. If nothing else is running, copy the lock ID from the message and run `terraform force-unlock LOCK-ID`.

---

## Stretch goals

1. **Cross-account.** Move the bucket into a second AWS account. You'll need a bucket policy, a role to assume, and the KMS key policy allowing the other account. This was Steve's follow-up question.
2. **Big files.** Lambda stops after 15 minutes. Send big files to an ECS Fargate task instead. Best Egg runs Fargate.
3. **Serverless Framework.** Keep Terraform for the foundations and deploy just the Lambda with `serverless.yml`. That's Best Egg's exact split.
4. **Apply exactly what was reviewed.** Save the plan from the pull request and apply that file, instead of planning again after the merge.
5. **Tighten the apply role.** It uses `AdministratorAccess` as a shortcut, and Checkov flags it. Replace it with a policy covering only the services this project uses.

## What's been checked

- Lambda tests: **4 passed**, against faked AWS.
- Terraform: `bootstrap/` and `infra/` pass `validate` and the formatting check, against AWS provider 6.68. (Checked with OpenTofu, which runs the same code.)
- The Lambda zip comes out the same on every computer, so GitHub's first run shows **No changes**.
- Checkov on `infra/`: **102 passed, 0 failed**, with Checkov 3.3.26, the same version the pipeline uses. 9 checks are skipped on purpose, each with its reason written next to it in the code.
- `bootstrap/` is run by hand and isn't scanned in the pipeline. It has 6 known findings. The important one is the `AdministratorAccess` shortcut — see stretch goal 5.
- **Not yet run in a real AWS account or on GitHub.** Your run is the first.

## How to talk about it in the panel

Only say what you've actually done. Run it first.

> After my conversation with Steve, I built a small version of the CSV scenario he gave me, on your kind of setup. Terraform for the foundation, with state in S3 instead of Terraform Cloud. S3 into SQS with a dead-letter queue, Lambda, DynamoDB, and KMS on everything.

> Every change goes through a pull request: tests, a Checkov scan, and the plan posted for review. It only deploys after approval, and GitHub uses short-lived credentials, not stored keys. It's the same change control you said Barclays is bringing in.

> I broke it on purpose. A bad file failed three times, went to the dead-letter queue, and the alarm emailed me. I found the cause in the logs and replayed it.

Two lessons worth mentioning, because they show you actually built it:

- **The KMS key policy has to allow S3 and CloudWatch.** Otherwise S3 can't write to the encrypted queue, and alarms can't email through the encrypted topic.
- **The S3 prefix filter matters.** The Lambda writes rejected rows into the same bucket. Without the `incoming/` filter, it would trigger itself in a loop.
