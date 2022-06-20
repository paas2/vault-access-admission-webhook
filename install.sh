#!/bin/bash

# Vault adress
export VAULT_ADDR='http://127.0.0.1:8200'

AUTH_PATH="sahab2-security-dev"

# Enable kubernetes login
vault auth enable -path=/$AUTH_PATH kubernetes

# Configure kubernetes authentication config
CONFIG_PATH="auth/${AUTH_PATH}/config"
VAULT_HELM_SECRET_NAME=$(kubectl get secrets -n vault --output=json | jq -r '.items[].metadata | select(.name|startswith("vault-token-")).name')
TOKEN_REVIEW_JWT=$(kubectl get secret -n vault $VAULT_HELM_SECRET_NAME --output='go-template={{ .data.token }}' | base64 --decode)
KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)
KUBE_HOST=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')
vault write $CONFIG_PATH \
    token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT" \
    issuer="https://kubernetes.default.svc.cluster.local" 

# Create policy for ms-secret-access-manager service account
ROLE_PATH="auth/${AUTH_PATH}/role"
vault policy write ms-secret-access-manager - <<EOF
# Create and manage ACL policies
path "sys/policies/acl/*"
{
  capabilities = ["create",  "update", "delete"]
}

# Manage auth methods broadly across Vault
path "$ROLE_PATH/*"
{
  capabilities = ["create",  "update", "delete"]
}
EOF

# Create role for ms-secret-access-manager service account
vault write $ROLE_PATH/ms-secret-access-manager \
    bound_service_account_names=ms-secret-access-manager \
    bound_service_account_namespaces=vault-access-definitions \
    policies=ms-secret-access-manager \
    ttl=24h

# Enable the PKI secrets engine at its default path.
vault secrets enable -path=/sahab2-pki pki

# By default the KPI secrets engine sets the time-to-live (TTL) to 30 days. A certificate can have its lease extended to ensure certificate rotation on a yearly basis (8760h). 
# Configure the max lease time-to-live (TTL) to 8760h.
vault secrets tune -max-lease-ttl=8760h sahab2-pki

# Generate a self-signed certificate valid for 8760h.
vault write sahab2-pki/root/generate/internal \
common_name=vault-access-admission-webhook.vault-access-definitions.svc \
ttl=8760h \
alt_names=vault-access-admission-webhook,vault-access-admission-webhook.vault-access-definitions,vault-access-admission-webhook.vault-access-definitions.svc

# Configure a role named config-admission-webhook that enables the creation of certificates  config-sidecar-injector-service domains with any subdomains.
vault write sahab2-pki/roles/vault-policy-webhook \
    allowed_domains=vault-access-admission-webhook \
    allowed_domains=vault-access-admission-webhook.vault-access-definitions \
    allowed_domains=vault-access-admission-webhook.vault-access-definitions.svc \
    allow_subdomains=true \
    allow_bare_domains=true \
    require_cn=false \
    max_ttl=10m

# Create a policy named pki that enables read access to the PKI secrets engine paths.
vault policy write sahab2-pki - <<EOF
path "sahab2-pki*"                                 { capabilities = ["read", "list"] }
path "sahab2-pki/roles/vault-policy-webhook"   { capabilities = ["create", "update"] }
path "sahab2-pki/sign/vault-policy-webhook"    { capabilities = ["create", "update"] }
path "sahab2-pki/issue/vault-policy-webhook"   { capabilities = ["create"] }
EOF

# Finally, create a Kubernetes authentication role named issuer that binds the pki policy with a Kubernetes service account named issuer.
vault write $ROLE_PATH/webhook-issuer \
    bound_service_account_names=webhook-issuer \
    bound_service_account_namespaces=vault-access-definitions \
    policies=sahab2-pki \
    ttl=20m