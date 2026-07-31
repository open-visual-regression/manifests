#!/usr/bin/env bash
# Creates the "ovr-secrets" Secret that helm/ovr (via existingSecret) reads.
# Run once against the prod cluster. Nothing produced here is written to
# this repo.
#
# Required env vars:
#   DATABASE_URL              Neon connection string
#   AWS_ACCESS_KEY_ID         IAM user scoped to the OVR S3 bucket only
#   AWS_SECRET_ACCESS_KEY
#
# BETTER_AUTH_SECRET and OVR_GIT_TOKEN_ENCRYPTION_KEY are generated for you.
#
# Usage:
#   kubectl config use-context <your-prod-context>
#   DATABASE_URL=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#     ./scripts/create-secrets.sh

set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
NAMESPACE="${NAMESPACE:-ovr}"

CURRENT_CONTEXT="$(kubectl config current-context)"
read -r -p "This will create/update ovr-secrets in namespace '${NAMESPACE}' on kubectl context '${CURRENT_CONTEXT}'. Continue? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted." >&2
  exit 1
fi

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

BETTER_AUTH_SECRET="$(openssl rand -base64 32)"
OVR_GIT_TOKEN_ENCRYPTION_KEY="$(openssl rand -base64 32)"
REDIS_URL="redis://valkey:6379"

kubectl create secret generic ovr-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=DATABASE_URL="${DATABASE_URL}" \
  --from-literal=REDIS_URL="${REDIS_URL}" \
  --from-literal=BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET}" \
  --from-literal=OVR_GIT_TOKEN_ENCRYPTION_KEY="${OVR_GIT_TOKEN_ENCRYPTION_KEY}" \
  --from-literal=STORAGE_ACCESS_KEY="${AWS_ACCESS_KEY_ID}" \
  --from-literal=STORAGE_SECRET_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ovr-secrets created/updated in namespace ${NAMESPACE}."
