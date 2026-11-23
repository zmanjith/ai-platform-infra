
#!/usr/bin/env bash
set -Eeuo pipefail

REGION="ap-southeast-2"
EXPECTED_ACCOUNT="491377098012"
CLUSTER_NAME="ai-platform-eks"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

echo "=========================================="
echo " AI PLATFORM - ENVIRONMENT STARTUP"
echo "=========================================="

# 1. AWS account safety check
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT" ]]; then
    echo "ERROR: Unexpected AWS account: $ACCOUNT_ID"
    exit 1
fi

echo "AWS account verified: $ACCOUNT_ID"

# 2. Required tools
for tool in terraform aws kubectl eksctl helm python3 jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: Required tool missing: $tool"
        exit 1
    }
done

# 3. Recreate ephemeral infrastructure
echo "[1/7] Creating EKS and networking infrastructure..."

terraform -chdir=ephemeral init
terraform -chdir=ephemeral validate
terraform -chdir=ephemeral apply -auto-approve

CLUSTER_NAME=$(terraform -chdir=ephemeral output -raw eks_cluster_name)
VPC_ID=$(terraform -chdir=ephemeral output -raw vpc_id)

ALB_ROLE_ARN=$(aws iam get-role \
    --role-name ai-platform-alb-controller-role \
    --query 'Role.Arn' \
    --output text)

# 4. Configure EKS access
echo "[2/7] Configuring EKS access..."

aws eks wait cluster-active \
    --region "$REGION" \
    --name "$CLUSTER_NAME"

aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER_NAME"

kubectl wait --for=condition=Ready nodes \
    --all --timeout=300s

# 5. Associate the new EKS OIDC provider
echo "[3/7] Associating EKS OIDC provider..."

eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --approve

# Update controller role trust policy
echo "Retrieving new EKS OIDC configuration..."

OIDC_ISSUER=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'cluster.identity.oidc.issuer' \
    --output text)

OIDC_ID="${OIDC_ISSUER#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${EXPECTED_ACCOUNT}:oidc-provider/${OIDC_ID}"

echo "Updating persistent ALB Controller OIDC configuration..."

python3 - "$ROOT_DIR/persistent/terraform.tfvars" "$OIDC_ISSUER" "$OIDC_PROVIDER_ARN" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
issuer, provider_arn = sys.argv[2], sys.argv[3]

content = path.read_text()
content, issuer_count = re.subn(
    r'(?m)^oidc_issuer\s*=.*$',
    f'oidc_issuer = "{issuer}"',
    content
)
content, arn_count = re.subn(
    r'(?m)^oidc_provider_arn\s*=.*$',
    f'oidc_provider_arn = "{provider_arn}"',
    content
)

if issuer_count != 1 or arn_count != 1:
    raise SystemExit("Expected exactly one OIDC variable of each type.")

path.write_text(content)
PY

terraform -chdir=persistent init
terraform -chdir=persistent validate
terraform -chdir=persistent apply -auto-approve

aws iam update-assume-role-policy \
    --role-name ai-platform-alb-controller-role \
    --policy-document file:///tmp/alb-controller-trust.json

# 6. Install AWS Load Balancer Controller
echo "[4/7] Installing AWS Load Balancer Controller..."

kubectl create serviceaccount aws-load-balancer-controller \
    --namespace kube-system \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate serviceaccount aws-load-balancer-controller \
    --namespace kube-system \
    "eks.amazonaws.com/role-arn=$ALB_ROLE_ARN" \
    --overwrite

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version 1.14.0 \
    --set clusterName="$CLUSTER_NAME" \
    --set region="$REGION" \
    --set vpcId="$VPC_ID" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --wait --timeout 5m

# 7. Install ArgoCD
echo "[5/7] Installing ArgoCD..."

kubectl create namespace argocd \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --server-side \
    -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server \
    -n argocd --timeout=300s

# Install Argo Rollouts
echo "[6/7] Installing Argo Rollouts..."

kubectl apply --server-side -k \
    "https://github.com/argoproj/argo-rollouts/manifests/crds?ref=stable"

kubectl create namespace argo-rollouts \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl rollout status deployment/argo-rollouts \
    -n argo-rollouts --timeout=300s

# 8. Restore GitOps application
echo "[7/7] Restoring ArgoCD application..."

APP_FILE="$ROOT_DIR/argocd/ai-platform-app.yaml"

if [[ -f "$APP_FILE" ]]; then
    kubectl apply -f "$APP_FILE"
else
    echo "ERROR: ArgoCD application manifest not found: $APP_FILE"
    exit 1
fi

echo
echo "=========================================="
echo " STARTUP COMPLETED"
echo "=========================================="

echo "Kubernetes nodes:"
kubectl get nodes

echo
echo "ArgoCD applications:"
kubectl get applications -n argocd

echo
echo "Ingress endpoints (allow time for ALB provisioning):"

for i in {1..40}; do
    kubectl get ingress -A

    if kubectl get ingress -A -o json |
        jq -e '[.items[] | select((.status.loadBalancer.ingress // []) | length == 0)] | length == 0' >/dev/null; then
        break
    fi

    sleep 15
done

echo
echo "ALB DNS names:"

kubectl get ingress -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" : "}{range .status.loadBalancer.ingress[*]}{.hostname}{end}{"\n"}{end}'

echo
echo "ALB Controller:"
kubectl get deployment aws-load-balancer-controller -n kube-system

echo
echo "Argo Rollouts:"
kubectl get pods -n argo-rollouts
