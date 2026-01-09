# access-gateway Helm Chart

Opinionated deployment of the secure access gateway inside Kubernetes with conditional sidecars and zero-trust defaults.

## Features (Phase 2)
- Single Deployment with optional mTLS (Envoy) sidecar, SSH fallback sidecar (mutually exclusive), and init container waiting for certs.
- Configurable mTLS config map and secret names; ExternalSecret integration for mTLS/SSH materials.
- PodDisruptionBudget toggle for HA and NetworkPolicy with restrictive ingress/egress.
- Service ports for HTTP placeholder, mTLS listener, and Envoy admin when mTLS is on.
- Minimal RBAC + ServiceAccount.

## Key Values
- `mtls.enabled` (bool): enable Envoy sidecar. Defaults to `true`.
- `mtls.proxy.port` / `mtls.proxy.adminPort`: listener/admin ports (default `10000`/`9901`).
- `mtls.proxy.upstreamHost` / `mtls.proxy.upstreamPort`: where Envoy forwards (default `localhost:8080`).
- `mtls.certSecretName`: secret with `ca.crt`, `tls.crt`, `tls.key`.
- `ssh.enabled` (bool): enable SSH fallback (only when mTLS disabled). `ssh.authorizedKeysSecretName` for keys.
- `externalSecrets.enabled`: create ExternalSecrets. Sub-keys: `externalSecrets.mtls.*`, `externalSecrets.ssh.*`, `externalSecrets.path`, `refreshInterval`.
- `pdb.enabled` and `pdb.minAvailable`: PodDisruptionBudget.
- `networkPolicy.enabled` and `networkPolicy.extraEgress`: egress/ingress controls.

See `values.yaml` for the full list.

## Usage (values excerpt)
```yaml
mtls:
  enabled: true
  proxy:
    port: 10000
    adminPort: 9901
    upstreamHost: localhost
    upstreamPort: 8080
  certSecretName: mtls-certs

ssh:
  enabled: false
  authorizedKeysSecretName: ssh-authorized-keys

externalSecrets:
  enabled: true
  backendType: awsParameterStore
  path: /production/gateway/
  mtls:
    enabled: true
    secretName: mtls-certs
    keys:
      ca: ca.crt
      cert: tls.crt
      key: tls.key
  ssh:
    enabled: false
    secretName: ssh-authorized-keys
    key: authorized_keys

pdb:
  enabled: true
  minAvailable: 1

networkPolicy:
  enabled: true
  extraEgress: []
```

## Notes
- ExternalSecrets expects a `ClusterSecretStore` named after `externalSecrets.backendType` (e.g., `awsParameterStore`).
- NetworkPolicy defaults allow only same-namespace ingress and DNS egress to kube-system; add `networkPolicy.extraEgress` for service-specific needs.
- Ensure secrets referenced by `mtls.certSecretName` and `ssh.authorizedKeysSecretName` exist or are created by ExternalSecrets.
