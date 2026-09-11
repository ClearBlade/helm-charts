{{/* Renders the topic:subscription pairs appended to PUBSUB_PROJECT1 */}}
{{- define "pubsub-emulator.topicList" -}}
{{- range .Values.topics }},{{ .name }}:{{ .subscription }}{{ end -}}
{{- end }}
