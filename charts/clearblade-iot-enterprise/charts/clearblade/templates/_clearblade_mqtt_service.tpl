{{- define "clearblade.mqttService" -}}
apiVersion: v1
kind: Service
metadata:
  name: clearblade-mqtt-service
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    app: clearblade
    slot: {{ .slot }}
{{ include "clearblade.labels" .root | indent 4 }}
  {{- if .root.Values.mqttLoadBalancer.annotations }}
  annotations:
    {{- toYaml .root.Values.mqttLoadBalancer.annotations | nindent 4 }}
  {{- end }}
spec:
  type: LoadBalancer
  {{- if .root.Values.mqttLoadBalancer.mqttIP }}
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
