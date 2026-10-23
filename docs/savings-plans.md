# Compute Savings Plans

Running Qdrant on EC2 in your own account makes the compute eligible for Savings Plans.

## What this module gives you

Every node is a plain On-Demand EC2 instance launched by an Auto Scaling group. That is exactly what **Compute Savings Plans** cover:

- Applies to any EC2 instance family, size, region, OS and tenancy, so changing `instance_type` or `architecture` never strands the commitment.
- Also covers Fargate and Lambda usage in the same account (or organisation).
- Does **not** cover EBS, S3, NLB, NAT, data transfer or CloudWatch. Those are billed normally. Only the compute is discounted.

Do not use Spot for Qdrant nodes: they hold your only copy of a shard's state and need a stable identity.

A Savings Plan is **not a Terraform resource**. You buy it in the console or CLI, at account (or organisation) level. The module only guarantees that the usage is eligible and tagged so you can see it.

## How to size a commitment

A Savings Plan is a commitment in dollars per hour for 1 or 3 years. Anything you use above the commitment is billed On-Demand, and unused commitment is lost.

1. Run the deployment for at least a couple of weeks at your real baseline.
2. In **Cost Explorer > Savings Plans > Recommendations**, choose Compute Savings Plans, the term and payment option, and look at AWS's recommended hourly commitment.
3. Commit to the steady-state floor, not the peak. If you scale between 3 and 6 nodes, commit based on 3.
4. Remember the plan is account-wide: other EC2 in the same account (or organisation, depending on sharing settings) consumes it first or too. Check **Utilization** so you are not paying for commitment nothing uses, and **Coverage** to see how much of your compute it discounts.

Payment options (No Upfront, Partial Upfront, All Upfront) and terms trade cash flow for discount. See the AWS Savings Plans pricing page for current rates, which vary by region and instance family.

## Alternatives

- **EC2 Instance Savings Plans** give a larger discount in exchange for locking to one instance family in one region. That suits a very stable Qdrant fleet, but it makes changing families (for example m7g to r7g) costly.
- **Reserved Instances** are less flexible than either plan and are rarely the right choice for a new deployment.

## Reading the bill

The module tags instances with `QdrantCluster` and `QdrantNodeIndex`. Activate `QdrantCluster` as a **cost allocation tag** in Billing so Cost Explorer can split Qdrant cost out from the rest of your account. Tags you pass in `tags` are inherited by instances and volumes too.

## Before you buy

- Confirm the baseline compute cost in your own account using the AWS Pricing Calculator for the instance type, node count, EBS volumes and NAT or NLB you chose.
- Remember that self-hosting adds your own operational time, which this module reduces but does not remove.
