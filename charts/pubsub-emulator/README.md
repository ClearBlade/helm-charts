# pubsub-emulator

Runs the Google Pub/Sub emulator as a standalone deployment, for ClearBlade
environments that need Pub/Sub connectors to work without reaching Google.

**Not for production.** The emulator holds all state in memory, performs no
authentication, and loses every topic, subscription and message when the pod
restarts.

This chart is deliberately independent of `clearblade-iot-enterprise` — it is
not a dependency of that chart and installs on its own release.

## Install

```sh
helm install pubsub-emulator ./charts/pubsub-emulator \
  --namespace pubsub --create-namespace \
  --set projectID=my-test-project \
  --set topics[0].name=my-registry \
  --set topics[0].subscription=my-registry-sub
```

Topics are usually easier to express in a values file:

```yaml
projectID: my-test-project
topics:
  - name: my-registry
    subscription: my-registry-sub
```

## Pointing ClearBlade at it

The Pub/Sub client inside ClearBlade is the official Google SDK
(`cloud.google.com/go/pubsub/v2`), which redirects to an emulator when
`PUBSUB_EMULATOR_HOST` is set in its environment. Set it through the
`clearblade` subchart's `extraEnv`:

```yaml
clearblade:
  extraEnv:
    - name: PUBSUB_EMULATOR_HOST
      value: "pubsub-emulator.pubsub.svc.cluster.local:8681"
```

Use the release name and namespace you installed this chart under.

### Read this before setting that variable

`PUBSUB_EMULATOR_HOST` is process-wide. Setting it redirects **every** Pub/Sub
MQTT connector in **every** system on that pod to the emulator, including
connectors holding valid production service account credentials. Those
connectors will appear to publish successfully while their messages go nowhere
real. Never set it on an installation that also serves production traffic.

The SDK ignores any credentials a connector supplies once the variable is set —
it prepends `option.WithoutAuthentication()` along with the emulator endpoint.

## Verifying

```sh
kubectl exec -n clearblade clearblade-0 -c clearblade -- env | grep PUBSUB
kubectl logs -n pubsub deploy/pubsub-emulator
```
