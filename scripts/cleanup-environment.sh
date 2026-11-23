#!/usr/bin/env bash
set -u

REGION="ap-southeast-2"
ACCOUNT="491377098012"

echo "======================================"
echo " AI PLATFORM - DAILY ENVIRONMENT CHECK"
echo "======================================"

echo
echo "[1] AWS identity"
aws sts get-caller-identity \
  --query '[Account,Arn]' --output table

echo
echo "[2] EKS clusters"
aws eks list-clusters --region "$REGION" --output table

echo
echo "[3] ECR repositories"
aws ecr describe-repositories --region "$REGION" \
  --query 'repositories[].[repositoryName,repositoryUri]' --output table

echo
echo "[4] Non-default VPCs"
aws ec2 describe-vpcs --region "$REGION" \
  --query 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock]' --output table

echo
echo "[5] EC2 instances"
aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-state-name,Values=running,pending,stopping,stopped \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' \
  --output table

echo
echo "[6] Load balancers"
aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output table

echo
echo "[7] EBS volumes"
aws ec2 describe-volumes --region "$REGION" \
  --query 'Volumes[].[VolumeId,State,Size]' --output table

echo
echo "[8] GitHub Actions IAM role"
aws iam get-role --role-name github-actions-ai-platform \
  --query 'Role.[RoleName,Arn]' --output table 2>/dev/null \
  || echo "Not found"

echo
echo "[9] ALB Controller IAM role"
aws iam get-role --role-name ai-platform-alb-controller-role \
  --query 'Role.[RoleName,Arn]' --output table 2>/dev/null \
  || echo "Not found"

echo
echo "[10] Terraform workspace and state"
terraform workspace show
terraform state list

echo
echo "Check complete. Review any resources returned above."
