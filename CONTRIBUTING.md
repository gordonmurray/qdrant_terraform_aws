# Contributing

Thanks for helping. Keep changes small and focused, and explain the reason for a change in the pull request.

## Set up

Install Terraform (`.terraform-version` has the minimum we test), [TFLint](https://github.com/terraform-linters/tflint), [terraform-docs](https://terraform-docs.io), and optionally [pre-commit](https://pre-commit.com) and [Trivy](https://trivy.dev).

```bash
pre-commit install
```

## Checks (CI runs the same)

```bash
terraform fmt -check -recursive
(cd modules/qdrant && terraform init -backend=false && terraform validate && terraform test)
for d in examples/single-node examples/cluster examples/production; do (cd "$d" && terraform init -backend=false && terraform validate); done
tflint --recursive
trivy config .
(cd modules/qdrant && terraform-docs .)   # regenerate the inputs/outputs tables
shellcheck scripts/*.sh
```

## Guidelines

- Every new variable needs a description, a type, a sensible default and validation when the value space is restricted. Run terraform-docs afterwards.
- Add or update a test in `modules/qdrant/tests/` for behaviour changes. Tests use a mocked provider, so they need no AWS credentials.
- Anything that changes how existing nodes behave (user data, config) must be called out in the changelog, because nodes are replaced deliberately, one at a time.
- Do not put secrets, account IDs or real hostnames in code, examples or docs.
- Update `CHANGELOG.md` under "Unreleased".
