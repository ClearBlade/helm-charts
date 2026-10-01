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
Listeners config for one slot, as JSON. Mirrors what the platform generates when it migrates the
legacy port and TLS settings, so the listeners match the flags on the statefulset.
Takes a dict with "root" and "terminateTls".
*/}}
{{- define "clearblade.listeners" -}}
{{- $v := .root.Values -}}
{{- $tls := .terminateTls -}}
{{- $cfg := $v.listeners -}}
{{- $rootRedirectUrl := include "clearblade.rootRedirectUrl" .root -}}

{{- $maxConnects := $cfg.broker.maxConcurrentConnectsPerNode -}}
{{- if kindIs "invalid" $maxConnects -}}
{{- $maxConnects = ternary 0 40 $tls -}}
{{- end -}}
{{- $broker := dict
  "BrokerAuthService" $cfg.broker.authService
  "BrokerAuthSystem" $cfg.broker.authSystem
  "BrokerBasicAuthDefaultSystem" $cfg.broker.basicAuthDefaultSystem
  "BrokerEnabledAuthMethods" (default (list) $cfg.broker.enabledAuthMethods)
  "BrokerMaxConcurrentConnectsPerNode" (int $maxConnects)
-}}

{{- $http := dict -}}
{{- $_ := set $http "app" (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.http.httpPort)
  "EnableHttpEndpoints" (not $tls)
  "AcmeOnly" $tls
  "EnableReverseProxy" $tls
  "RootRedirectURL" $rootRedirectUrl
) -}}
{{- if $tls -}}
{{- $_ := set $http "app_tls" (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.http.httpTLSPort)
  "UseTLS" true
  "EnableHttpEndpoints" true
  "EnableReverseProxy" true
  "RootRedirectURL" $rootRedirectUrl
) -}}
{{- end -}}
{{- if $v.global.mtlsClearBlade -}}
{{- $_ := set $http "app_mtls" (merge (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.http.httpMTLSPort)
  "UseMTLS" true
  "EnableHttpEndpoints" true
  "EnableReverseProxy" $tls
  "BrokerALPN" $v.http.mtlsBrokerALPN
) (ternary $broker (dict) (ne $v.http.mtlsBrokerALPN ""))) -}}
{{- end -}}
{{- $mqttWsRoutes := list "/mqtt" "/edge_shell" -}}
{{- $_ := set $http "mqtt_ws" (merge (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.brokerWSPort)
  "EnableWebsockets" true
  "EnabledWebsocketRoutes" $mqttWsRoutes
) $broker) -}}
{{- if $tls -}}
{{- $_ := set $http "mqtt_ws_tls" (merge (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.brokerWSSPort)
  "UseTLS" true
  "EnableWebsockets" true
  "EnabledWebsocketRoutes" $mqttWsRoutes
) $broker) -}}
{{- end -}}
{{- $_ := set $http "mqtt_auth_ws" (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.messagingAuthWSPort)
  "EnableWebsockets" true
  "EnabledWebsocketRoutes" (list "/mqtt_auth")
) -}}
{{- if $tls -}}
{{- $_ := set $http "mqtt_auth_ws_tls" (dict
  "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.messagingAuthWSSPort)
  "UseTLS" true
  "EnableWebsockets" true
  "EnabledWebsocketRoutes" (list "/mqtt_auth")
) -}}
{{- end -}}

{{- $mqtt := dict "mqtt" (merge (dict "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.brokerTCPPort)) $broker) -}}
{{- if $tls -}}
{{- $_ := set $mqtt "mqtt_tls" (merge (dict "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.brokerTLSPort) "UseTLS" true) $broker) -}}
{{- end -}}

{{- $mqttAuth := dict "mqtt_auth" (dict "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.messagingAuthPort)) -}}
{{- if $tls -}}
{{- $_ := set $mqttAuth "mqtt_auth_tls" (dict "ListenAddress" (include "clearblade.listenAddress" $v.mqtt.messagingAuthTLSPort) "UseTLS" true) -}}
{{- end -}}

{{- $rpc := dict
  "internal" (dict "ListenAddress" (include "clearblade.listenAddress" $v.rpc.portInternal) "IsInternal" true)
  "external" (dict "ListenAddress" (include "clearblade.listenAddress" $v.rpc.port))
-}}
{{- if $tls -}}
{{- $_ := set $rpc "external_tls" (dict "ListenAddress" (include "clearblade.listenAddress" $v.rpc.tlsPort) "UseTLS" true) -}}
{{- end -}}

{{- $sections := dict "HTTPListeners" $http "MQTTListeners" $mqtt "MQTTAuthListeners" $mqttAuth "RPCListeners" $rpc -}}
{{- $overrideSections := dict "HTTPListeners" $cfg.http "MQTTListeners" $cfg.mqtt "MQTTAuthListeners" $cfg.mqttAuth "RPCListeners" $cfg.rpc -}}
{{- range $section, $overrides := $overrideSections -}}
{{- $listeners := get $sections $section -}}
{{- range $name, $override := $overrides -}}
{{- if and (hasKey $override "enabled") (not $override.enabled) -}}
{{- $_ := unset $listeners $name -}}
{{- /* A listener only generated for TLS slots is left alone on other slots */ -}}
{{- else if or (hasKey $listeners $name) (hasKey $override "ListenAddress") -}}
{{- $listener := default (dict) (get $listeners $name) -}}
{{- /* Set key by key since mergeOverwrite skips false, 0 and "" */ -}}
{{- range $key, $value := omit $override "enabled" -}}
{{- $_ := set $listener $key $value -}}
{{- end -}}
{{- $_ := set $listeners $name $listener -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $sections -}}
{{- end }}

{{/*
[Listeners] tables for clearblade.toml. Takes the same dict as "clearblade.listeners".
*/}}
{{- define "clearblade.listenersToml" -}}
{{- range $section, $listeners := include "clearblade.listeners" . | fromJson }}
{{- range $name, $listener := $listeners }}

[Listeners.{{ $section }}.{{ $name }}]
{{- range $key, $value := $listener }}
{{ $key }} = {{ include "clearblade.tomlValue" $value }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "clearblade.tomlValue" -}}
{{- if kindIs "float64" . -}}
{{- if eq (floor .) . }}{{ int64 . }}{{ else }}{{ . }}{{ end -}}
{{- else if or (kindIs "bool" .) (kindIs "int" .) (kindIs "int64" .) -}}
{{- . -}}
{{- else if or (kindIs "string" .) (kindIs "slice" .) -}}
{{- toJson . -}}
{{- else -}}
{{- fail (printf "clearblade.listeners: unsupported value %v" .) -}}
{{- end -}}
{{- end }}
