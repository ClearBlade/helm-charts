{{/*
Root redirect URL for the HTTP listeners. Keep in sync with -root-redirect-url in the statefulset.
*/}}
{{- define "clearblade.rootRedirectUrl" -}}
{{- if ne .Values.rootRedirectUrl "" -}}
{{- .Values.rootRedirectUrl -}}
{{- else if or .Values.global.iotCoreEnabled .Values.global.iotCoreSaasEnabled -}}
/iot-core
{{- else if .Values.global.opsConsoleEnabled -}}
/ops-console
{{- end -}}
{{- end }}

{{- define "clearblade.listenAddress" -}}
{{- $addr := toString . -}}
{{- if contains ":" $addr }}{{ $addr }}{{ else }}:{{ $addr }}{{ end -}}
{{- end }}

{{/*
[Listeners] tables for clearblade.toml. Matches what the platform's listeners migration generates from the
settings the statefulset passes as flags, with platform defaults for ports the chart never set.
Takes a dict with "root" and "terminateTls".
*/}}
{{- define "clearblade.listenersToml" -}}
{{- $v := .root.Values -}}
{{- $tls := .terminateTls -}}
{{- $rootRedirectUrl := include "clearblade.rootRedirectUrl" .root -}}
{{- /* -max-concurrent-connects-per-node is 0 when terminating TLS, otherwise the platform default */ -}}
{{- $broker := dict "BrokerMaxConcurrentConnectsPerNode" (ternary 0 40 $tls) -}}
{{- $listeners := list -}}

{{- $app := dict "ListenAddress" $v.http.httpPort "EnableHttpEndpoints" (not $tls) "AcmeOnly" $tls "EnableReverseProxy" $tls -}}
{{- if $rootRedirectUrl }}{{ $_ := set $app "RootRedirectURL" $rootRedirectUrl }}{{ end -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app" $app) -}}
{{- if $tls -}}
{{- $appTls := dict "ListenAddress" ":9002" "UseTLS" true "EnableHttpEndpoints" true "EnableReverseProxy" true -}}
{{- if $rootRedirectUrl }}{{ $_ := set $appTls "RootRedirectURL" $rootRedirectUrl }}{{ end -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app_tls" $appTls) -}}
{{- end -}}
{{- if $v.global.mtlsClearBlade -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app_mtls" (merge (dict "ListenAddress" $v.http.httpMTLSPort "UseMTLS" true "EnableHttpEndpoints" true "EnableReverseProxy" $tls "BrokerALPN" "clearblade_mqtt_mtls") $broker)) -}}
{{- end -}}

{{- $mqttWs := dict "EnableWebsockets" true "EnabledWebsocketRoutes" (list "/mqtt" "/edge_shell") -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_ws" (merge (dict "ListenAddress" $v.mqtt.brokerWSPort) $mqttWs $broker)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_ws_tls" (merge (dict "ListenAddress" $v.mqtt.brokerWSSPort "UseTLS" true) $mqttWs $broker)) -}}
{{- end -}}
{{- $mqttAuthWs := dict "EnableWebsockets" true "EnabledWebsocketRoutes" (list "/mqtt_auth") -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_auth_ws" (merge (dict "ListenAddress" $v.mqtt.messagingAuthWSPort) $mqttAuthWs)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_auth_ws_tls" (merge (dict "ListenAddress" ":8908" "UseTLS" true) $mqttAuthWs)) -}}
{{- end -}}

{{- $listeners = append $listeners (list "MQTTListeners" "mqtt" (merge (dict "ListenAddress" $v.mqtt.brokerTCPPort) $broker)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "MQTTListeners" "mqtt_tls" (merge (dict "ListenAddress" $v.mqtt.brokerTLSPort "UseTLS" true) $broker)) -}}
{{- end -}}

{{- $listeners = append $listeners (list "MQTTAuthListeners" "mqtt_auth" (dict "ListenAddress" $v.mqtt.messagingAuthPort)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "MQTTAuthListeners" "mqtt_auth_tls" (dict "ListenAddress" ":8906" "UseTLS" true)) -}}
{{- end -}}

{{- $listeners = append $listeners (list "RPCListeners" "internal" (dict "ListenAddress" $v.rpc.portInternal "IsInternal" true)) -}}
{{- $listeners = append $listeners (list "RPCListeners" "external" (dict "ListenAddress" $v.rpc.port)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "RPCListeners" "external_tls" (dict "ListenAddress" ":8951" "UseTLS" true)) -}}
{{- end -}}

{{- range $listeners }}
{{- $fields := index . 2 }}

[Listeners.{{ index . 0 }}.{{ index . 1 }}]
ListenAddress = {{ include "clearblade.listenAddress" $fields.ListenAddress | quote }}
{{- range $key, $value := omit $fields "ListenAddress" }}
{{ $key }} = {{ if kindIs "string" $value }}{{ $value | quote }}{{ else if kindIs "slice" $value }}{{ toJson $value }}{{ else }}{{ $value }}{{ end }}
{{- end }}
{{- end }}
{{- end }}
