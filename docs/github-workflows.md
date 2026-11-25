# GitHub Actions workflow

The [build, scan and push workflow](../.github/workflows/build-scan-push.yml)
runs on pull requests targeting `main` and on pushes to `main` or `feature/*`
branches. Its single job runs on `ubuntu-latest` with `contents: read`.

## Build, scan and push

The job checks out the source, sets up QEMU for ARM64 and configures Docker
Buildx. It then configures AWS credentials and logs in to Amazon ECR.

The job builds an ARM64 image, loads it into Docker and tags it as:

```text
340268328991.dkr.ecr.eu-west-2.amazonaws.com/sas/hof-nginx:<github.sha>
```

The workflow checks that the authenticated ECR registry matches this
configured registry before building. The tag is the GitHub Actions
`github.sha` for the event; for a pull request this is normally the merge
commit SHA.

The pinned Home Office scan action runs Trivy against the image for HIGH and
CRITICAL OS and library vulnerabilities. A failed scan prevents the push.
After a successful scan, the job pushes the image to ECR. This push also
applies to pull request and feature branch runs when credentials are available;
it is not restricted to `main`. The workflow does not run the local smoke
tests or send Slack notifications.

## Required secrets

Configure these GitHub Actions secrets for the repository:

| Secret | Purpose |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | AWS access key used to authenticate to ECR. |
| `AWS_SECRET_ACCESS_KEY` | Corresponding AWS secret access key. |
| `AWS_REGION` | AWS region; it must match the configured ECR registry. |

The AWS identity needs permission to authenticate to ECR and push to the
configured repository. GitHub does not normally provide repository secrets
to workflows triggered by pull requests from forks, so those runs cannot
authenticate and push without an approved alternative.

The production and non-production reusable workflow jobs and Slack
notification in the workflow file are commented out; their secrets are not
required by the active job.

## Action updates and Node.js warning

Actions are pinned to commit SHAs. Dependabot checks GitHub Actions
dependencies weekly; review action changes and test the workflow before
merging updates.

The directly referenced QEMU, Buildx and AWS credentials actions use Node.js
24. The pinned scan action calls a Trivy action that still references
`actions/cache` on Node.js 20; the Trivy setup action also references that
cache version. GitHub may warn that these nested actions are being forced to
run on Node.js 24. Resolving that warning requires updates to those upstream
actions and then updating the pinned scan action to a revision that uses them.
