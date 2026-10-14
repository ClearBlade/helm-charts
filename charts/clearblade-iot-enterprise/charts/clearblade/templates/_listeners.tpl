{{- /* Root redirect URL for the HTTP listeners */ -}}
{{- define "clearblade.rootRedirectUrl" -}}
{{- if ne .Values.rootRedirectUrl "" -}}
{{- .Values.rootRedirectUrl -}}
{{- else if or .Values.global.iotCoreEnabled .Values.global.iotCoreSaasEnabled -}}
/iot-core
{{- else if .Values.global.opsConsoleEnabled -}}
/ops-console
{{- end -}}
{{- end }}

{{- /* Template to normalize listen addresses */ -}}
{{- define "clearblade.listenAddress" -}}
{{- $addr := toString . -}}
{{- if contains ":" $addr }}{{ $addr }}{{ else }}:{{ $addr }}{{ end -}}
{{- end }}

{{- define "clearblade.listenersToml" -}}
{{- $v := .root.Values -}}
{{- $tls := .terminateTls -}}
{{- $rootRedirectUrl := include "clearblade.rootRedirectUrl" .root -}}
{{- $listeners := list -}}

{{- /* Broker settings for listeners that serve MQTT clients */ -}}
{{- $broker := dict -}}
{{- if gt (int $v.mqtt.maxConcurrentConnectsPerNode) 0 -}}
{{- $_ := set $broker "BrokerMaxConcurrentConnectsPerNode" (int $v.mqtt.maxConcurrentConnectsPerNode) -}}
{{- end -}}
{{- with $v.mqtt.brokerAuthService }}{{ $_ := set $broker "BrokerAuthService" . }}{{ end -}}
{{- with $v.mqtt.brokerAuthSystem }}{{ $_ := set $broker "BrokerAuthSystem" . }}{{ end -}}
{{- with $v.mqtt.basicAuthDefaultSystem }}{{ $_ := set $broker "BrokerBasicAuthDefaultSystem" . }}{{ end -}}
{{- with $v.mqtt.enabledAuthMethods }}{{ $_ := set $broker "BrokerEnabledAuthMethods" . }}{{ end -}}

{{- /* HTTP Listeners */ -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app" (dict "ListenAddress" $v.http.httpPort "AcmeOnly" true)) -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app_tls" (dict "ListenAddress" ":9002" "UseTLS" true "EnableHttpEndpoints" true "EnableReverseProxy" true "RootRedirectURL" $rootRedirectUrl)) -}}
{{- else -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app" (dict "ListenAddress" $v.http.httpPort "EnableHttpEndpoints" true "RootRedirectURL" $rootRedirectUrl)) -}}
{{- end -}}
{{- if $v.global.mtlsClearBlade -}}
{{- $mtls := dict "ListenAddress" $v.http.httpMTLSPort "UseMTLS" true "EnableHttpEndpoints" true "EnableReverseProxy" $tls -}}
{{- with $v.security.mtlsMqttAlpn -}}
{{- $mtls = merge $mtls (dict "BrokerALPN" .) $broker -}}
{{- end -}}
{{- $listeners = append $listeners (list "HTTPListeners" "app_mtls" $mtls) -}}
{{- end -}}

{{- /* MQTT WS */ -}}
{{- $mqttWs := dict "EnableWebsockets" true "EnabledWebsocketRoutes" (list "/mqtt" "/edge_shell") -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_ws" (merge (dict "ListenAddress" $v.mqtt.brokerWSPort) $mqttWs $broker)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_ws_tls" (merge (dict "ListenAddress" $v.mqtt.brokerWSSPort "UseTLS" true) $mqttWs $broker)) -}}
{{- end -}}

{{- /* MQTT Auth WS */ -}}
{{- $mqttAuthWs := dict "EnableWebsockets" true "EnabledWebsocketRoutes" (list "/mqtt_auth") -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_auth_ws" (merge (dict "ListenAddress" $v.mqtt.messagingAuthWSPort) $mqttAuthWs)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "HTTPListeners" "mqtt_auth_ws_tls" (merge (dict "ListenAddress" ":8908" "UseTLS" true) $mqttAuthWs)) -}}
{{- end -}}

{{- /* MQTT */ -}}
{{- $listeners = append $listeners (list "MQTTListeners" "mqtt" (merge (dict "ListenAddress" $v.mqtt.brokerTCPPort) $broker)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "MQTTListeners" "mqtt_tls" (merge (dict "ListenAddress" $v.mqtt.brokerTLSPort "UseTLS" true) $broker)) -}}
{{- end -}}

{{- /* MQTT Auth */ -}}
{{- $listeners = append $listeners (list "MQTTAuthListeners" "mqtt_auth" (dict "ListenAddress" $v.mqtt.messagingAuthPort)) -}}
{{- if $tls -}}
{{- $listeners = append $listeners (list "MQTTAuthListeners" "mqtt_auth_tls" (dict "ListenAddress" ":8906" "UseTLS" true)) -}}
{{- end -}}

{{- /* RPC */ -}}
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
