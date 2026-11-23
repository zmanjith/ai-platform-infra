#!/usr/bin/env bash
set -euo pipefail

echo "AI Platform cleanup"
echo "-------------------"
echo "Cleanup is not enabled yet."
echo
echo "ECR and GitHub OIDC currently share Terraform state"
echo "with EKS and networking."
echo
echo "A full terraform destroy would delete persistent resources."
echo "We must separate persistent and temporary resources first."
echo
echo "No AWS resources have been changed."
exit 1