# Enable the PKI secrets engine at its default path.
$ vault secrets enable pki
Success! Enabled the pki secrets engine at: pki/

# By default the KPI secrets engine sets the time-to-live (TTL) to 30 days. A certificate can have its lease extended to ensure certificate rotation on a yearly basis (8760h). 
# Configure the max lease time-to-live (TTL) to 8760h.
$ vault secrets tune -max-lease-ttl=8760h pki
Success! Tuned the secrets engine at: pki/

# Vault can accept an existing key pair, or it can generate its own self-signed root. In general, we recommend maintaining your root CA outside of Vault and providing Vault a signed intermediate CA.
# Generate a self-signed certificate valid for 8760h.
$ vault write pki/root/generate/internal \
common_name=vault-policy-webhook.enbd.com.vault-access-definitions.svc \
ttl=8760h \
alt_names=vault-policy-webhook.enbd.com,vault-policy-webhook.enbd.com.vault-access-definitions,vault-policy-webhook.enbd.com.vault-access-definitions.svc

# Configure the PKI secrets engine certificate issuing and certificate revocation list (CRL) endpoints to use the Vault service in the default namespace.
$ vault write pki/config/urls \
    issuing_certificates="http://localhost:8200/v1/pki/ca" \
    crl_distribution_points="http://localhost:8200/v1/pki/crl"

Success! Data written to: pki/config/urls

# Configure a role named config-admission-webhook that enables the creation of certificates  config-sidecar-injector-service domains with any subdomains.
$ vault write pki/roles/vault-policy-webhook \
 allowed_domains=vault-policy-webhook.enbd.com \
 allowed_domains=vault-policy-webhook.enbd.com.vault-access-definitions \
 allowed_domains=vault-policy-webhook.enbd.com.vault-access-definitions.svc \
 allow_subdomains=true \
 allow_bare_domains=true \
 require_cn=false \
 max_ttl=10m
 Success! Data written to: pki/roles/config-admission-webhook

# The role, config-admission-webhook, is a logical name that maps to a policy used to generate credentials. This generates a number of endpoints that are used by the Kubernetes service account to issue and sign these certificates. A policy must be created that enables these paths.
# Create a policy named pki that enables read access to the PKI secrets engine paths.
$ vault policy write pki - <<EOF
path "pki*"                                 { capabilities = ["read", "list"] }
path "pki/roles/vault-policy-webhook"   { capabilities = ["create", "update"] }
path "pki/sign/vault-policy-webhook"    { capabilities = ["create", "update"] }
path "pki/issue/vault-policy-webhook"   { capabilities = ["create"] }
EOF