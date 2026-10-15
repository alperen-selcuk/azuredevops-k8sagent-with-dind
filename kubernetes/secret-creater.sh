#!/bin/bash
set -euo pipefail

read -r -p "AZUREDEVOPS_URL : " URL
read -r -s -p "AZUREDEVOPS_PAT : " PAT
echo
read -r -p "AZUREDEVOPS_POOL : " POOL
read -r -p "KUBERNETES NAMESPACE : " NS

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic azdevops \
  --from-literal=AZP_URL="${URL}" \
  --from-literal=AZP_TOKEN="${PAT}" \
  --from-literal=AZP_POOL="${POOL}" \
  -n "${NS}"
