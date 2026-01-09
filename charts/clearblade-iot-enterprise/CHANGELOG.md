# Changelog

## [3.2.1] - 2025-07-24

Let's Encrypt Certificate Auto-Renewal: The chart now defaults to enabling automatic renewal for Let's Encrypt certificates. This is found in the cb-haproxy subchart

## [3.2.2] - 2025-08-05

Port Additions: Added optional configurable unsecure ports for mtls-auth

## [3.3.0] - 2025-08-05

GDC Support: Added required functionality to support GDC deployments

## [3.3.1] - 2025-08-14

Haproxy Controller: Added functionality to support secondary MQTT URL in certificates generated. Opened port 80 on MQTT URL

## [3.3.2] - 2025-08-22

Ports: All ports for both the primary and mqtt URL's are now configurable. Bug fix in metric and license renewal webhooks

## [3.3.3] - 2025-08-28

Requires platform version 2025.2.2

Ciphers: Haproxy allows the use of weaker ciphers for backwards compatitibility. Disabled by default. New value cb-haproxy.useWeakCiphers

Log Format: ClearBlade now sets the config flag 'log-format' to json. This cannot be overwritten.

## [3.3.4] - 2025-09-10

Haproxy: Updates the log format to add detail for debugging

## [3.3.5] - 2025-09-11

ClearBlade: Adds helm value for database config toml

## [3.3.6] - 2025-09-17

ClearBlade: Add platform flag config for messagingURL

Haproxy: Add new optional port for secondary unsecure mqtt traffic 

## [3.3.7] - 2025-09-18

ClearBlade: changed order of flag configurations due to platform bug; Fixed mtls config bug in charts

## [3.3.8] - 2025-09-22

ClearBlade: Add persistent volume to file hosting container

## [3.4.0] - 2025-09-23

Haproxy Controller: ACME can now be done with multiple domains and any ACME directory. The `clearblade-gsm-read` service account must have the Secret Manager Admin role.

## [3.4.1] - 2025-09-26

All pods: All pods now have individual nodeselectors, allowing for fine grained node distribution

## [3.4.3] - 2025-11-10

Haproxy: MQTT listeners can serve a different TLS certificate than other listeners.

## [3.5.0] - 2025-11-24

File Hosting: Add HMAC secret to verify signature of incoming requests.

## [3.5.1] - 2025-12-09

Redis: Added configurable setting for maxconnections to redis

ClearBlade: Added optional env variable for GODEBUG: madvdontneed=1

## [3.5.2] - 2025-12-17

IA, IoTCore and File Hosting: Changed deployment strategy from rolling update to recreate

ClearBlade: Changed statefulsets to allow for rollout partitions on changes