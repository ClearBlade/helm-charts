{{- define "clearblade.mqttService" -}}
apiVersion: v1
kind: Service
metadata:
  name: clearblade-mqtt-service
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    app: clearblade
    slot: {{ .slot }}
{{- include "clearblade.labels" .root | nindent 4 }}
  {{- if or .root.Values.mqttLoadBalancer.annotations (eq .root.Values.global.cloud "aws") (eq .root.Values.global.cloud "doks") }}
  annotations:
    {{- if eq .root.Values.global.cloud "aws" }}
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-subnets: {{ default "us-east-2a" .root.Values.global.subnet }}
    {{- if .root.Values.mqttLoadBalancer.mqttIP }}
    service.beta.kubernetes.io/aws-load-balancer-eip-allocations: {{ .root.Values.mqttLoadBalancer.mqttIP }}
    {{- end }}
    {{- else if eq .root.Values.global.cloud "doks" }}
    service.beta.kubernetes.io/do-loadbalancer-name: clearblade-mqtt-service
    {{- end }}
    {{- with .root.Values.mqttLoadBalancer.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  type: LoadBalancer
  {{- if and .root.Values.mqttLoadBalancer.mqttIP (ne .root.Values.global.cloud "aws") (ne .root.Values.global.cloud "doks") }}
  loadBalancerIP: {{ .root.Values.mqttLoadBalancer.mqttIP }}
  {{- end }}
  externalTrafficPolicy: Local
  ports:
    - name: http
      targetPort: 9000
      port: 80
      protocol: TCP
    {{- if .root.Values.mqttLoadBalancer.enableMqtt }}
    - name: mqtt
      targetPort: 1884
      port: {{ .root.Values.mqttLoadBalancer.mqttPort }}
      protocol: TCP
    {{- end }}
    {{- if .root.Values.mqttLoadBalancer.enableSecondaryMqtt }}
    - name: mqtt-secondary
      targetPort: 1884
      port: {{ .root.Values.mqttLoadBalancer.secondaryMqttPort }}
      protocol: TCP
    {{- end }}
  selector:
    app: clearblade
    slot: {{ .slot }}
{{- end }}
