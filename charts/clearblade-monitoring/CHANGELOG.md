# Changelog

## [2.15.1] - 2025-09-26

Prometheus Volume: Corrected Prometheus Volume to correctly mount to disks in GCP.

## [2.15.2] - 2025-10-22

High CPU/High Memory Alerts: Fixed issue that could result in alerts not firing.

## [2.15.3] - 2025-10-29

License Alerts now default to the high channel, alert 7 days from expiry, and only fire once daily

Added customer name to all alert names

## [2.15.4] - 2025-11-04

OOM alerts now resolve correctly

Closed unnecessary ports

Corrected PVC size request

## [2.15.5] - 2025-11-25

Added Retention rate to prometheus, defaulting to 70% of disk size

Added image puller secret to haproxy for init container

## [2.15.6] - 2025-12-09

Added alert for Redis connection pool nearing max out