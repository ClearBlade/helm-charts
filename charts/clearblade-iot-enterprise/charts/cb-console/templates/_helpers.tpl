{{/*
Expand the name of the chart.
*/}}
{{- define "cb-console.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create platformURL flag arg
*/}}
{{- define "cb-console.platformURL" -}}
{{- if (.Values.global.enterprisePlatformURL) }}
"-platformURL={{ .Values.global.enterprisePlatformURL }}"
{{- else }}
"-platformURL=https://{{ .Values.global.enterpriseBaseURL }}"
{{- end }}
{{- end }}

{{/*
Create websocket messagingURL flag arg
*/}}
{{- define "cb-console.wsMqttMessagingURL" -}}
{{- if (.Values.global.enterpriseWsMqttMessagingURL) }}
"-messageURL={{ .Values.global.enterpriseWsMqttMessagingURL }}"
{{- else }}
"-messageURL={{ .Values.global.enterpriseBaseURL }}"
{{- end }}
{{- end }}

{{/*
Create websocket messagingPort flag arg
*/}}
{{- define "cb-console.wsMqttMessagingPort" -}}
{{- if (.Values.global.enterpriseWsMqttMessagingPort) }}
"-messagePort={{ .Values.global.enterpriseWsMqttMessagingPort }}"
{{- else }}
"-messagePort=8904"
{{- end }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cb-console.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cb-console.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cb-console.labels" -}}
helm.sh/chart: {{ include "cb-console.chart" . }}
{{ include "cb-console.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cb-console.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cb-console.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cb-console.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cb-console.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
