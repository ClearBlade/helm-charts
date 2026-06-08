{{- define "clearblade.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    slot: {{ .slot }}

spec:
  {{- if .reverse_proxy_enabled }}
  type: LoadBalancer
  loadBalancerIP: {{ .primaryIP }}
  ports:
    {{- if .reverseProxy.enableHttp }}
    - name: api
      port: {{ .reverseProxy.httpPort }}
      targetPort: 9000
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableHttps }}
    - name: api-https
      port: {{ .reverseProxy.httpsPort }}
      targetPort: 9002
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMtls }}
    - name: mtls
      port: {{ .reverseProxy.mtlsPort }}
      targetPort: 9001
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttInsecure }}
    - name: mqtt
      port: {{ .reverseProxy.mqttInsecurePort }}
      targetPort: 1883
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqtt }}
    - name: mqtt-tls
      port: {{ .reverseProxy.mqttPort }}
      targetPort: 1884
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttWsInsecure }}
    - name: mqtt-ws
      port: {{ .reverseProxy.mqttWsInsecurePort }}
      targetPort: 8903
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttWs }}
    - name: mqtt-ws-tls
      targetPort: 8904
      port: {{ .reverseProxy.mqttWsPort }}
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttAuthInsecure }}
    - name: mqtt-auth
      targetPort: 8905
      port: {{ .reverseProxy.mqttAuthInsecurePort }}
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttAuth }}
    - name: mqtt-auth-tls
      targetPort: 8906
      port: {{ .reverseProxy.mqttAuthPort }}
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttWsAuthInsecure }}
    - name: mqtt-ws-auth
      targetPort: 8907
      port: {{ .reverseProxy.mqttWsAuthInsecurePort }}
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableMqttWsAuth }}
    - name: mqtt-ws-auth-tls
      targetPort: 8908
      port: {{ .reverseProxy.mqttWsAuthPort }}
      protocol: TCP
    {{- end }}
    {{- if .reverseProxy.enableEdgeRpc }}
    - name: edge-rpc
      targetPort: 8951
      port: {{ .reverseProxy.edgeRpcPort }}
      protocol: TCP
    {{- end }}
  {{- else }}
  ports:
    - name: mqtt
      port: 1883
      targetPort: 1883
      protocol: TCP
    - name: mqtt-ws
      targetPort: 8903
      port: 8903
      protocol: TCP
    - name: mqtt-auth
      targetPort: 8905
      port: 8905
      protocol: TCP
    - name: mqtt-ws-auth
      targetPort: 8907
      port: 8907
      protocol: TCP
    - name: edge-rpc
      targetPort: 8950
      port: 8950
      protocol: TCP
    - name: api
      targetPort: 9000
      port: 9000
      protocol: TCP
    - name: mtls
      targetPort: 9001
      port: 9001
      protocol: TCP
  {{- end }}
  selector:
    app: clearblade
    slot: {{ .slot }}
{{- end}}