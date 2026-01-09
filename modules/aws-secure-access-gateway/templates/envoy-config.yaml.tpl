# Basic Envoy configuration for mTLS termination and TCP forwarding.
static_resources:
  listeners:
    - name: mtls_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: ${listener_port}
      filter_chains:
        - filters:
            - name: envoy.filters.network.tcp_proxy
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
                stat_prefix: tcp_proxy
                cluster: forward_cluster
          transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
              require_client_certificate: true
              common_tls_context:
                tls_certificates:
                  - certificate_chain:
                      filename: /etc/ssl/envoy/tls.crt
                    private_key:
                      filename: /etc/ssl/envoy/tls.key
                validation_context:
                  trusted_ca:
                    filename: /etc/ssl/envoy/ca.crt

  clusters:
    - name: forward_cluster
      connect_timeout: 5s
      type: LOGICAL_DNS
      load_assignment:
        cluster_name: forward_cluster
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: ${upstream_host}
                      port_value: ${upstream_port}
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
