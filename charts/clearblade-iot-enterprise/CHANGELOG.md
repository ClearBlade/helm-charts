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