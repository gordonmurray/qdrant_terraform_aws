# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately using GitHub's "Report a vulnerability" feature on this repository (Security tab), or email the maintainers at the address listed in the repository profile. Include the module version, a description, and steps to reproduce. You will get an acknowledgement within a few working days.

## Scope and design notes

- Nodes have no SSH and no key pair; access is through SSM Session Manager.
- IMDSv2 is required; the IAM role is limited to the resources of one deployment.
- API keys are stored in Secrets Manager and are fetched at start-up, never rendered into user data. Generated keys are stored in Terraform state: use an encrypted remote backend with restricted access.
- Node-to-node traffic is not encrypted. Keep Qdrant in private subnets; TLS to clients is available at the NLB with an ACM certificate.
- This is community-maintained infrastructure code. Review it and test restores before you rely on it for production data.
