# Chart Versioning Policy

The `clearblade-iot-enterprise` chart follows semantic versioning (`MAJOR.MINOR.PATCH`).

## Version Format: `MAJOR.MINOR.PATCH`

### PATCH (e.g. 3.8.0 -> 3.8.1)

No-downtime changes. Safe to `helm upgrade` without restarting critical containers.

Examples:
- Values-only additions (new optional fields with backwards-compatible defaults)
- Non-critical container image updates (cb-console, cb-file-hosting, cb-ops-console, cb-tiles)
- Config changes that take effect on reload (haproxy.cfg updates picked up by `haproxy -sf`)
- Documentation, label, or annotation changes
- Bug fixes that don't alter pod specs of critical containers
- Adding new optional subcharts

### MINOR (e.g. 3.8.1 -> 3.9.0)

Changes that require a restart of one or more critical containers to take effect. Existing values files continue to work without modification.

Critical containers (restart = brief downtime or disruption):
- **cb-postgres** (database — connections drop, potential failover)
- **clearblade** (platform StatefulSet — API/MQTT unavailable during rollout)
- **cb-haproxy** (load balancer — traffic interruption)
- **cb-redis** (cache/session store — cache invalidation, possible reconnect storms)
- **cb-iotcore** (IoT Core sidecar — device connectivity interruption)
- **cb-ia** (Intelligent Assets sidecar — IA unavailable during restart)

Examples:
- Env var additions/changes on a critical container's pod spec
- Volume mount changes on a critical container
- Resource limit changes on a critical container
- Init container additions or changes for critical pods
- Security context changes on critical containers
- New sidecar containers added to critical pods
- PostgreSQL config changes that require a restart (`max_wal_senders`, `max_replication_slots`, etc.)

### MAJOR (e.g. 3.9.0 -> 4.0.0)

Breaking changes that require every deployment's values file to be updated before upgrading.

Examples:
- Renamed or removed values keys
- Changed defaults that alter behavior for existing deployments
- New required values (no backwards-compatible default possible)
- Structural changes to how secrets, volumes, or services are defined
- Dropping support for a cloud provider or secret manager
- PostgreSQL major version upgrade path changes
- Migration steps required beyond `helm upgrade`

## Applying a Version Bump

1. Update `version` in `Chart.yaml`
2. Update `version` in each subchart's `Chart.yaml` to match
3. Update the dependency versions in the parent `Chart.yaml` to match
4. Tag the release commit as `clearblade-iot-enterprise-{version}`

## When in Doubt

- If a change touches the pod spec of a critical container in any way, it is at least a **MINOR** bump.
- If a change requires editing existing values files, it is a **MAJOR** bump.
- If unsure whether a container restart is needed, assume it is and bump **MINOR**.
