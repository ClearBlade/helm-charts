{{- define "clearblade.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: clearblade-service
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    {{- if .root.Values.global.enterpriseSlot }}
    slot: {{ .root.Values.global.enterpriseSlot }}
    {{- else }}
    slot: blue
    {{- end }}
spec:
  {{- if .root.Values.reverseProxy.enabled }}
  type: LoadBalancer
  loadBalancerIP: {{.root.Values.primaryIP}}
  ports:
    {{- if .root.Values.reverseProxy.enableHttp }}
    - name: api
      port: {{ .root.Values.reverseProxy.httpPort }}
      targetPort: 9000
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableHttps }}
    - name: api-https
      port: {{ .root.Values.reverseProxy.httpsPort }}
      targetPort: 9002
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMtls }}
    - name: mtls
      port: {{ .root.Values.reverseProxy.mtlsPort }}
      targetPort: 9001
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttInsecure }}
    - name: mqtt
      port: {{ .root.Values.reverseProxy.mqttInsecurePort }}
      targetPort: 1883
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqtt }}
    - name: mqtt-tls
      port: {{ .root.Values.reverseProxy.mqttPort }}
      targetPort: 1884
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttWsInsecure }}
    - name: mqtt-ws
      port: {{ .root.Values.reverseProxy.mqttWsInsecurePort }}
      targetPort: 8903
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttWs }}
    - name: mqtt-ws-tls
      targetPort: 8904
      port: {{ .root.Values.reverseProxy.mqttWsPort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttAuthInsecure }}
    - name: mqtt-auth
      targetPort: 8905
      port: {{ .root.Values.reverseProxy.mqttAuthInsecurePort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttAuth }}
    - name: mqtt-auth-tls
      targetPort: 8906
      port: {{ .root.Values.reverseProxy.mqttAuthPort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttWsAuthInsecure }}
    - name: mqtt-ws-auth
      targetPort: 8907
      port: {{ .root.Values.reverseProxy.mqttWsAuthInsecurePort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableMqttWsAuth }}
    - name: mqtt-ws-auth-tls
      targetPort: 8908
      port: {{ .root.Values.reverseProxy.mqttWsAuthPort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.reverseProxy.enableEdgeRpc }}
    - name: edge-rpc
      targetPort: 8951
      port: {{ .root.Values.reverseProxy.edgeRpcPort }}
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
    {{- if .root.Values.global.enterpriseSlot }}
    slot: {{ .root.Values.global.enterpriseSlot }}
    {{- else }}
    slot: blue
    {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: clearblade-cluster-nodes-service
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    app: clearblade
{{ include "clearblade.labels" .root | indent 4 }}
spec:
  clusterIP: None
  ports:
    - name: clearblade-node
      targetPort: 8952
      port: 8952
      protocol: TCP
  selector:
    app: clearblade
{{- if eq (default .root.Values.global.gmpEnabled false) false }}
---
{{- if .root.Values.global.monitoringEnabled }}
{{- range $i, $e := until (.root.Values.blueReplicas | int)}}
apiVersion: v1
kind: Service
metadata:
  name: clearblade-monitoring-service-{{$i}}
  namespace: {{ default "clearblade" $.root.Values.global.namespace }}
  labels:
    run: clearblade
    slot: blue
spec:
  ports:
  - name: metrics
    port: 2112
    protocol: TCP
  selector:
    statefulset.kubernetes.io/pod-name: clearblade-{{$i}}
---
{{- end }}
{{- range $i, $e := until (.root.Values.greenReplicas | int)}}
apiVersion: v1
kind: Service
metadata:
  name: clearblade-monitoring-service-green-{{$i}}
  namespace: {{ default "clearblade" $.root.Values.global.namespace }}
  labels:
    run: clearblade
    slot: green
spec:
  ports:
  - name: metrics
    port: 2112
    protocol: TCP
  selector:
    statefulset.kubernetes.io/pod-name: clearblade-green-{{$i}}
---
{{- end}}
{{- end}}
{{- end}}
{{- end}}