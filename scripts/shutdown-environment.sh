
#!/usr/bin/env bash
set -Eeuo pipefail

REGION="ap-southeast-2"
EXPECTED_ACCOUNT="491377098012"
CLUSTER_NAME="ai-platform-eks"
ECR_REPOSITORY="ai-platform-app"
GITHUB_OIDC_ROLE="github-actions-ai-platform"
ALB_CONTROLLER_ROLE="ai-platform-alb-controller-role"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EPHEMERAL_DIR="$ROOT_DIR/ephemeral"

cd "$ROOT_DIR"

echo "=========================================="
echo " AI PLATFORM - ENVIRONMENT SHUTDOWN"
echo "=========================================="

# --------------------------------------------------
# 1. Verify AWS identity and required tools
# --------------------------------------------------

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT" ]]; then
    echo "ERROR: Unexpected AWS account: $ACCOUNT_ID"
    exit 1
fi

echo "AWS account verified: $ACCOUNT_ID"

for tool in aws kubectl terraform jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: Missing required tool: $tool"
        exit 1
    }
done

if [[ ! -d "$EPHEMERAL_DIR" ]]; then
    echo "ERROR: Ephemeral Terraform directory not found: $EPHEMERAL_DIR"
    exit 1
fi

# --------------------------------------------------
# 2. Check whether the EKS cluster exists
# --------------------------------------------------

CLUSTER_EXISTS=false

if CLUSTER_INFO=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" 2>&1); then

    CLUSTER_EXISTS=true
    echo "EKS cluster found: $CLUSTER_NAME"

    aws eks update-kubeconfig \
        --region "$REGION" \
        --name "$CLUSTER_NAME"

else
    if [[ "$CLUSTER_INFO" == *ResourceNotFoundException* ]]; then
        echo "EKS cluster does not exist."
        echo "Will check for remaining ephemeral resources."
    else
        echo "ERROR: Unable to check EKS cluster:"
        echo "$CLUSTER_INFO"
        exit 1
    fi
fi

# --------------------------------------------------
# 3. Disable ArgoCD automated sync
# --------------------------------------------------

if [[ "$CLUSTER_EXISTS" == true ]]; then

    echo "[1/5] Disabling ArgoCD automated sync..."

    # Disable automated sync on existing Applications.
    if kubectl get applications.argoproj.io \
        -n argocd >/dev/null 2>&1; then

        while IFS= read -r APP; do
            [[ -z "$APP" ]] && continue

            echo "Disabling auto-sync: $APP"

            kubectl patch application.argoproj.io "$APP" \
                -n argocd \
                --type merge \
                -p '{"spec":{"syncPolicy":{"automated":null}}}'

        done < <(
            kubectl get applications.argoproj.io \
                -n argocd \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
        )
    fi

    # Also disable automated sync in ApplicationSet templates,
    # if ApplicationSets are being used.
    if kubectl get applicationsets.argoproj.io \
        -n argocd >/dev/null 2>&1; then

        while IFS= read -r APPSET; do
            [[ -z "$APPSET" ]] && continue

            echo "Disabling ApplicationSet auto-sync: $APPSET"

            kubectl patch applicationset.argoproj.io "$APPSET" \
                -n argocd \
                --type merge \
                -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":null}}}}}'

        done < <(
            kubectl get applicationsets.argoproj.io \
                -n argocd \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
        )
    fi

    # --------------------------------------------------
    # 4. Remove Ingress resources
    # --------------------------------------------------

    echo "[2/5] Removing Ingress resources..."

    kubectl delete ingress --all --all-namespaces \
        --wait=true \
        --timeout=180s

else
    echo "[1/5] Skipping Kubernetes cleanup: cluster is absent."
    echo "[2/5] Skipping Ingress deletion: cluster is absent."
fi

# --------------------------------------------------
# 5. Wait for cluster-managed AWS Load Balancers
# --------------------------------------------------

echo "[3/5] Waiting for AWS Load Balancers to disappear..."

DEADLINE=$((SECONDS + 600))
REMAINING=0

while (( SECONDS < DEADLINE )); do

    REMAINING=0

    LB_ARNS=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query 'LoadBalancers[].LoadBalancerArn' \
        --output text)

    # Handle an empty load-balancer list.
    if [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]]; then
        echo "No AWS Load Balancers remain."
        break
    fi

    for ARN in $LB_ARNS; do

        MATCH=$(aws elbv2 describe-tags \
            --region "$REGION" \
            --resource-arns "$ARN" \
            --query "length(TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='${CLUSTER_NAME}'])" \
            --output text)

        # The query should return a numeric count.
        if [[ ! "$MATCH" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Unexpected tag query result for $ARN: $MATCH"
            exit 1
        fi

        if (( MATCH > 0 )); then
            ((REMAINING += 1))
        fi
    done

    if (( REMAINING == 0 )); then
        echo "No cluster-managed Load Balancers remain."
        break
    fi

    echo "$REMAINING cluster-managed Load Balancer(s) remain."
    sleep 15

done

# Never destroy networking while cluster-managed LBs remain.
if (( REMAINING > 0 )); then
    echo "ERROR: Load Balancer cleanup timed out."
    echo "Refusing to destroy networking infrastructure."
    exit 1
fi

# --------------------------------------------------
# 6. Initialise and validate ephemeral Terraform state
# --------------------------------------------------

echo "[4/5] Preparing ephemeral Terraform destruction..."

terraform -chdir="$EPHEMERAL_DIR" init

STATE_RESOURCES=$(terraform -chdir="$EPHEMERAL_DIR" state list)

if ! grep -q '^module\.eks\.' <<< "$STATE_RESOURCES"; then
    echo "ERROR: module.eks was not found in ephemeral Terraform state."
    echo "Refusing to continue."
    exit 1
fi

if ! grep -q '^module\.networking\.' <<< "$STATE_RESOURCES"; then
    echo "ERROR: module.networking was not found in ephemeral Terraform state."
    echo "Refusing to continue."
    exit 1
fi

echo
echo "Terraform working directory: $EPHEMERAL_DIR"
echo "Terraform resources selected for destruction:"
echo "- module.eks"
echo "- module.networking"
echo
echo "The following will be preserved:"
echo "- ECR repository and container images"
echo "- GitHub Actions OIDC role and provider"
echo "- AWS Load Balancer Controller IAM role and policy"
echo

read -r -p "Continue with shutdown? Type yes to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Shutdown cancelled."
    exit 0
fi

# Destroy only the EKS and networking modules.
terraform -chdir="$EPHEMERAL_DIR" destroy \
    -target=module.eks \
    -target=module.networking \
    -auto-approve

# --------------------------------------------------
# 7. Verify persistent resources
# --------------------------------------------------

echo "[5/5] Verifying persistent AWS resources..."

aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$ECR_REPOSITORY" >/dev/null

echo "ECR repository preserved: $ECR_REPOSITORY"

aws iam get-role \
    --role-name "$GITHUB_OIDC_ROLE" >/dev/null

echo "GitHub Actions IAM role preserved: $GITHUB_OIDC_ROLE"

aws iam get-role \
    --role-name "$ALB_CONTROLLER_ROLE" >/dev/null

echo "ALB Controller IAM role preserved: $ALB_CONTROLLER_ROLE"

echo
echo "=========================================="
echo " ENVIRONMENT SHUTDOWN COMPLETED"
echo "=========================================="
echo "EKS and networking resources have been destroyed."
echo "Persistent resources have been retained."
echo "=========================================="
