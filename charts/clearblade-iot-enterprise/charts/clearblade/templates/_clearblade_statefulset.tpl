{{- define "clearblade.statefulset" -}}
{{- $pullCertsFromSecretManager := and .root.Values.global.mtlsClearBlade (not .root.Values.useDbTlsCerts) -}}
{{- $rootRedirectUrl := "" -}}
{{- if ne .root.Values.rootRedirectUrl "" -}}
{{- $rootRedirectUrl = .root.Values.rootRedirectUrl -}}
{{- else if .root.Values.global.iotCoreEnabled -}}
{{- $rootRedirectUrl = "/iot-core" -}}
{{- else if .root.Values.global.opsConsoleEnabled -}}
{{- $rootRedirectUrl = "/ops-console" -}}
{{- end -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ .name }}
  namespace: {{ default "clearblade" .root.Values.global.namespace }}
  labels:
    app: clearblade
spec:
  selector:
    matchLabels:
      app: clearblade
      slot: {{ .slot }}
  serviceName: clearblade-cluster-nodes-service
  replicas: {{ .replicas }}
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: {{ .partition }}
  template:
    metadata:
      labels:
        app: clearblade
        slot: {{ .slot }}
        app.kubernetes.io/name: managed-prom
    spec:
      {{- if eq .root.Values.global.secretManager "gsm" }}
      serviceAccountName: clearblade-gsm-read
      {{- end }}
      {{- if .root.Values.global.imagePullerSecret }}
      imagePullSecrets:
        - name: gcr-json-key
      {{- end }}
      tolerations:
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 0
      - key: node.kubernetes.io/unreachable
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 0
      initContainers:
      {{- if .root.Values.checkReadiness}}
        {{- if not .root.Values.global.gcpCloudSQLEnabled }}
        - name: check-postgres-readiness
          image: postgres:9.6.5
          command: 
          - sh 
          - "-c"
          - |
            until pg_isready -h cb-postgres-headless.{{ default "clearblade" .root.Values.global.namespace }}.svc.cluster.local -p 5432;
            do echo waiting for database; sleep 2; done;
        {{- end }}
        - name: check-redis-readiness
          image: redis:5.0-alpine
          {{- if .root.Values.global.gcpMemoryStoreEnabled }}
          command: 
          - sh 
          - "-c"
          - |
            set -x;
            while [ "$(redis-cli -h {{ .root.Values.global.gcpMemoryStoreAddress }} ping)" != "PONG" ]
            do
              echo waiting for redis
              sleep 5
            done
          {{- else }}
          command: 
          - sh 
          - "-c"
          - |
            set -x;
            while [ "$(redis-cli -h cb-redis-service.{{ default "clearblade" .root.Values.global.namespace }}.svc.cluster.local ping)" != "PONG" ]
            do
              echo waiting for redis
              sleep 5
            done
          {{- end }}
      {{- end }}  
        {{- if $pullCertsFromSecretManager }}
        - name: pull-mtls-certificate
          image: gcr.io/api-project-320446546234/cb_controller:cli-latest
          env: 
            - name: CERT_DIR
              value: etc/clearblade/ssl
            - name: PROJECT
              value: {{ .root.Values.global.gcpProject }}
            - name: NAMESPACE
              value: {{ .root.Values.global.namespace }}
            - name: PULL_ONLY
              value: "true"
            - name: DOMAIN_TO_PULL
              value: {{ .root.Values.global.enterpriseBaseURL }}
            - name: OUTPUT_FILE
              value: clearblade-0.pem

          volumeMounts:
            - name: mtls-cert-volume
              mountPath: /etc/clearblade/ssl/
        {{- end }}
        - name: init
          {{- if eq .root.Values.global.secretManager "gsm"}}
          {{- if .root.Values.global.arm }}
          image: gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine
          {{- else }}
          image: google/cloud-sdk:slim
          {{- end }}
          {{- end }}
          {{- if eq .root.Values.global.secretManager "asm"}}
          image: amazon/aws-cli:latest
          {{- end }}
          {{- if eq .root.Values.global.cloud "gdc"}}
          image: "{{ .root.Values.initImage }}"
          {{- end }}
          command: ["/bin/bash"]
          args:
            - -c
            - |
              {{- if eq .root.Values.global.secretManager "asm"}}
              yum install -y hostname
              {{- end}}
              set -ex
              # Generate clearblade host from pod ordinal index.
              [[ `hostname` =~ -([0-9]+)$ ]] || exit 1
              ordinal=${BASH_REMATCH[1]}
              # Copy appropriate conf.d files from config-map to emptyDir.
              cp /config-map/clearblade.toml /etc/clearblade/conf/clearblade/clearblade.toml
              # Add an offset to avoid reserved server-id=0 value.
              sed -i 's|{clearblade_node_number}|'$ordinal'|g'  /etc/clearblade/conf/clearblade/clearblade.toml
              # Add blue/green slot to host address
              sed -i 's|{slot}|'{{ .node_suffix }}'|g'  /etc/clearblade/conf/clearblade/clearblade.toml
              {{- if eq .root.Values.global.secretManager "gsm"}}
              dbpassword=$(gcloud secrets versions access latest --project={{ .root.Values.global.gcpProject }} --secret={{ default "clearblade" .root.Values.global.namespace }}_postgres-primary-password)
              {{- end }}
              {{- if eq .root.Values.global.secretManager "asm"}}
              dbpassword=$(aws secretsmanager get-secret-value --secret-id {{ default "clearblade" .root.Values.global.namespace }}_postgres-primary-password --region us-east-1 --query SecretString --output text)
              {{- end }}
              {{ if .root.Values.global.gcpCloudSQLConnectionName }}
              sed -i 's|{db_password}|'${dbpassword}'|g' /etc/clearblade/conf/clearblade/clearblade.toml
              {{- else }}
              escaped_dbpassword=$(printf '%s\n' "$dbpassword" | sed -e 's/[\/&]/\\&/g')
              sed -i 's|{db_password}|'$escaped_dbpassword'|g' /etc/clearblade/conf/clearblade/clearblade.toml
              {{- end }}
              {{- if eq .root.Values.global.secretManager "gsm"}}
              gcloud secrets versions access latest --project={{ .root.Values.global.gcpProject }} --secret={{ default "clearblade" .root.Values.global.namespace }}_clearblade-mek >> /etc/clearblade/mek/cb_platform_mek
              {{- else if eq .root.Values.global.secretManager "asm"}}
              aws secretsmanager get-secret-value --secret-id {{ default "clearblade" .root.Values.global.namespace }}_clearblade-mek --region us-east-1 --query SecretString --output text >> /etc/clearblade/mek/cb_platform_mek
              {{- else }}
              echo $mekfile >> /etc/clearblade/mek/cb_platform_mek
              {{- end }}
              {{- if eq .root.Values.global.secretManager "gsm" }}
              gcloud secrets versions access latest --project={{ .root.Values.global.gcpProject }} --secret={{ default "clearblade" .root.Values.global.namespace }}_filehosting-hmac-secret >> /etc/clearblade/conf/clearblade/filehosting_hmac_secret
              {{- else if eq .root.Values.global.secretManager "asm"}}
              aws secretsmanager get-secret-value --secret-id {{ default "clearblade" .root.Values.global.namespace }}_filehosting-hmac-secret --region us-east-1 --query SecretString --output text >> /etc/clearblade/conf/clearblade/filehosting_hmac_secret
              {{- else }}
              echo $filehosting_hmac_secret >> /etc/clearblade/conf/clearblade/filehosting_hmac_secret
              {{- end }}
          {{ if and (ne .root.Values.global.secretManager "gsm") (ne .root.Values.global.secretManager "asm")}}
          env:
            - name: dbpassword
              valueFrom:
                secretKeyRef:
                  name: clearblade-secrets
                  key: postgresPassword
            - name: mekfile
              valueFrom:
                secretKeyRef:
                  name: clearblade-secrets
                  key: mekfile
            - name: filehosting_hmac_secret
              valueFrom:
                secretKeyRef:
                  name: clearblade-secrets
                  key: filehosting_hmac_secret
          {{- end }}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/clearblade/conf/clearblade/
            - name: config-map
              mountPath: /config-map/
            - name: mek
              mountPath: /etc/clearblade/mek/
            {{- if $pullCertsFromSecretManager }}
            - name: mtls-cert-volume
              mountPath: /etc/clearblade/ssl/
            {{- end}}   
      containers:
        {{- if .root.Values.global.gcpCloudSQLConnectionName }}
        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.1.0
          args:
            - "--private-ip"
            - "--structured-logs"
            - "--port=5432"
            - {{ .root.Values.global.gcpCloudSQLConnectionName }}
          securityContext:
            runAsNonRoot: true
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
        {{- end }}
        - name: clearblade
          image: {{ .clearblade_image }}
          command: ["clearblade"]
          args:
            - "-config=/etc/clearblade/conf/clearblade/clearblade.toml"
          #DB
            {{- if and (not .root.Values.global.externalPostgresHost) (not .root.Values.global.gcpCloudSQLEnabled) }}
            #Default Postgres in these charts
            - "-db-host=cb-postgres-0.cb-postgres-headless.{{ default "clearblade" .root.Values.global.namespace }}.svc.cluster.local"
            - "-db-port=5432"
            {{- end }}
            #CloudSQL
            {{- if .root.Values.global.gcpCloudSQLEnabled}}
            - "-db-host=127.0.0.1"
            - "-disable-timescale=true"
            {{- else if .root.Values.global.externalPostgresHost}}
            #External DB
            - "-db-host={{ .root.Values.global.externalPostgresHost }}"
            - "-db-port={{ .root.Values.global.externalPostgresPort}}"
            {{- end }}
            - "-db-type={{ .root.Values.database.dbType }}"
            - "-db={{ .root.Values.database.dbStore }}"
          #FH
            - "-file-hosting-url=http://cb-file-hosting-service.{{ default "clearblade" .root.Values.global.namespace }}.svc.cluster.local:8915"
            - "-file-hosting-hmac-secret-location=/etc/clearblade/conf/clearblade/filehosting_hmac_secret"
          #CACHE
            {{ if .root.Values.global.gcpMemoryStoreEnabled }}
            - "-skip-setting-notify-keyspace-events=true"
            - "-store-addr={{ .root.Values.global.gcpMemoryStoreAddress }}"
            {{- else}}
            - "-store-addr=cb-redis-service.{{ default "clearblade" .root.Values.global.namespace }}.svc.cluster.local"
            {{- end }}
            - "-store-port=6379"
            - "-store=redis"
          #PLATFORM
            - "-registration-key={{ .root.Values.global.enterpriseRegistrationKey }}"
            - "-url={{- include "clearblade-iot-enterprise.platformURL" .root | trim }}"
            - "-addr={{ .root.Values.http.httpPort }}"
            - "-messaging-addr={{ .root.Values.mqtt.brokerTCPPort }}"
            - "-websocket-messaging-addr={{ .root.Values.mqtt.brokerWSPort }}"
            - "-message-auth-addr={{ .root.Values.mqtt.messagingAuthPort }}"
            - "-message-auth-websocket={{ .root.Values.mqtt.messagingAuthWSPort }}"
            {{- if .root.Values.global.enterpriseMQTTURL}}
            - "-messaging-url={{ .root.Values.global.enterpriseMQTTURL }}"
            {{- else }}
            - "-messaging-url={{- .root.Values.global.enterpriseBaseURL }}"
            {{- end }}
            - "-mek-storage-location=/etc/clearblade/mek"
            {{- if .root.Values.license.key }}
            - "-pkey={{ .root.Values.license.key }}"
            {{- end }}
            - "-platform-id={{ .root.Values.global.enterpriseInstanceID }}"
            - "-license-renewal-webhooks={{ join "," .root.Values.license.renewalWebhooks }}"
            - "-metrics-reporting-webhooks={{ join "," .root.Values.license.metricsWebhooks }}"
            - "-license-auto-renew-days={{ .root.Values.license.autoRenew.days }}"
            - "-auto-renew-license={{ .root.Values.license.autoRenew.enabled }}"
            {{- if $pullCertsFromSecretManager }}
            - "-cert=/etc/clearblade/ssl/clearblade-0.pem"
            {{- end }}
            {{- if .root.Values.global.mtlsClearBlade }}
            - "-enable-mutual-tls-auth=true"
            - "-check-certificate-cn-for-mtls=false"
            {{- end }}
            {{- if .terminate_tls }}
            - "-enable-reverse-proxy=true"
            - "-use-tls-http=true"
            - "-message-use-tls=true"
            - "-message-auth-use-tls=true"
            - "-message-ws-use-tls=true"
            - "-message-auth-ws-use-tls=true"
            - "-rpc-use-tls=true"
            - "-console-host=cb-console-service"
            - "-ia-host=cb-ia-service"
            - "-iotcore-host=cb-iotcore-service"
            - "-ops-console-host=cb-ops-console-service"
            - "-enable-automatic-certificate-renewal=true"
            {{- end }}
            {{- if .root.Values.enableWeakCiphers }}
            - "-weak-ciphers=true"
            {{- end }}
            - "-min-tls-version={{ .root.Values.minTlsVersion }}"
            {{- if ne $rootRedirectUrl "" }}
            - "-root-redirect-url={{ $rootRedirectUrl }}"
            {{- end }}
            - "-log-format=json"
          {{- if .madvdontneed}}
          env:
            - name: GODEBUG
              value: netdns=go,madvdontneed=1
          {{- else}}
          env:
            - name: GODEBUG
              value: netdns=go
          {{- end }}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/clearblade/conf/clearblade/
            - name: mek
              mountPath: /etc/clearblade/mek/
            {{- if $pullCertsFromSecretManager }}
            - name: mtls-cert-volume
              mountPath: /etc/clearblade/ssl/
            {{- end}}
          resources:
            requests:
              cpu: {{ .root.Values.requestCPU }}
              memory: {{ .root.Values.requestMemory }}
            limits:
              cpu: {{ .root.Values.limitCPU }}
              memory: {{ .root.Values.limitMemory }}
          ports:
            - containerPort: 2112
              name: metrics
      {{- if .root.Values.global.tolerations }}
      tolerations:
{{ .root.Values.global.tolerations | toYaml | indent 6 }}
      {{- end }}
      {{- if .root.Values.tolerations }}
      tolerations:
{{ .root.Values.tolerations | toYaml | indent 6 }}
      {{- end }}
      {{- if .node_selector }}
      nodeSelector:
        {{ .node_selector }}
      {{- end}}
      volumes:
        - name: config-volume
          emptyDir: {}
        - name: config-map
          secret:
            secretName: clearblade-config
        - name: mek
          emptyDir: {}
        {{- if $pullCertsFromSecretManager }}
        - name: mtls-cert-volume
          emptyDir: {}
        {{- end}}
{{- end }}