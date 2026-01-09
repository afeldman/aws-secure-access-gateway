{{/*
Standard labels for the access-gateway chart.
*/}}
{{- define "access-gateway.labels" -}}
helm.sh/chart: {{ include "access-gateway.chart" . }}
{{ include "access-gateway.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels for the access-gateway chart.
*/}}
{{- define "access-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "access-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "access-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "access-gateway.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "access-gateway.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the chart name and version as used by the chart label.
*/}}
{{- define "access-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Define the envoy config to be used in the configmap
*/}}
{{- define "access-gateway.envoyConfig" -}}
# In-cluster Envoy configuration for mTLS
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: {{ .Values.mtls.proxy.port }}
    filter_chains:
    - filter_chain_match:
        transport_protocol: "tls"
    - filters:
      - name: envoy.filters.network.tcp_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
          stat_prefix: tcp_proxy
          cluster: "forward_cluster"
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain:
                filename: "/etc/ssl/envoy/tls.crt"
              private_key:
                filename: "/etc/ssl/envoy/tls.key"
            validation_context:
              trusted_ca:
                filename: "/etc/ssl/envoy/ca.crt"
          require_client_certificate: true
  clusters:
  - name: forward_cluster
    connect_timeout: 5s
    type: STRICT_DNS
    # This service name will be resolved via K8s DNS.
    # The actual service to connect to will be determined by the 'connect.sh' script
    # logic which would use kubectl port-forwarding or a similar mechanism.
    load_assignment:
      cluster_name: forward_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: {{ .Values.mtls.proxy.upstreamHost }}
                port_value: {{ .Values.mtls.proxy.upstreamPort }}
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .Values.mtls.proxy.adminPort }}
{{- end -}}

{{/*
Define the sshd config to be used in the configmap
*/}}
{{- define "access-gateway.sshdConfig" -}}
Port {{ .Values.ssh.port }}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /home/ssh-user/.ssh/authorized_keys
Subsystem sftp /usr/lib/openssh/sftp-server
{{- end -}}
