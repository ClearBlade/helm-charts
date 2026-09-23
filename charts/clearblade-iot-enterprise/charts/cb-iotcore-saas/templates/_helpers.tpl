{{/*
The sidecar's config file, minus the developer password. Rendered as a dict so both
the Secret (which adds the password) and the ConfigMap the init container merges over
can build on it without repeating the field list.

Nothing extra may leak in here: the sidecar parses this file with DisallowUnknownFields
and exits non-zero on a key it does not recognise.
*/}}
{{- define "cb-iotcore-saas.baseConfig" -}}
{{- $cfg := dict
  "platformURL" (.Values.platformURL | default (printf "https://%s" (.Values.global.enterpriseBaseURL | toString)))
  "adminSystemKey" .Values.adminSystemKey
  "devEmail" .Values.devEmail
  "port" 8080
  "regions" (.Values.regions | default dict) -}}
{{- if .Values.skipUpdates }}{{- $_ := set $cfg "skipUpdates" true }}{{- end }}
{{- $cfg | toJson -}}
{{- end -}}
