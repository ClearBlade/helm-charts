# helm-charts
Repository for helm charts to deploy the ClearBlade IoT Enterprise platform and monitoring

# ClearBlade IoT Enterprise

The `clearblade-iot-enterprise` Helm chart enables you install an instance of the platform in your own infrastructure. The Helm charts support installing in your own Kubernetes environment, or within Google Cloud.

## Kubernetes

To install in your own Kubernetes cluster please use the `gke-default-values.yaml` file in this repo for configuring this instance. This includes the basic configurations required for installing into a normal Kubernetes environment.

## Google Cloud

When installing ClearBlade IoT Enterprise in Google Cloud, a few different services are leveraged to ensure a secure and optimized install. Specifically you will need these services enabled to successfully deploy:

- Google Kubernetes Engine
- Google Secret Manager
- Google Disk
- Google IP Address
- Google Service Account

Before installing the instance with these Helm charts, the following resources within Google Cloud must be created first:

### Required Resources

#### Kubernetes Cluster

It is recommended to create a Kubernetes Standard Cluster for your deployment, with the following configuration items:

- Regional Cluster
- Specify default node locations (2 zones max)
- Static default version
- Cluster autoscaler enabled
- Min and Max number of nodes per zone set
- Disable Automatically upgrade nodes to next available version
- N2 series machines
- Enable Workload Identify under Cluster Security
- Enable Managed Service for Prometheus under Cluster Features

#### IP Addresses

At minimum you will need 1 static public IP address provisioned to allow access to your ClearBlade IoT Enterprise from the public internet. Optinally a second IP address can be provisioned to enable MQTT connections over port 443. Using both IP addresses is the recommended configuration. These 2 IP addresses should be created in the same Region as your GKE Cluster.

#### Disks

Dedicated Disks are required for persisting data within your ClearBlade IoT Enterprise platform. If you are deploying with a Streaming Replica Postgres instance you will need a dedicated disk for each instance, with the same configuration for each disk. The naming of these disks must also follow a specific pattern, and match the number of Postgres replicas you deploy with:

```
<namespace>-postgres-0
<namespace>-postgres-1
...
```

Type: Regional SSD Persistent Disk  
Size: 100 GB  
Zones: Must match the 2 zones configured in the GKE cluster  
Snapshots: Enabled at your preferred schedule for backup purposes  

#### Secrets

The following 5 Secrets are required, and must follow the specific naming pattern provided, replacing `<namespace>` with the namespcae you are deploying your instance in:

| Secret Name    | Value   |
| -------------- | ------- |
| `<namespace>_clearblade-mek`  | Provided by ClearBlade    |
| `<namespace>_postgres-postgres-password` | Postgres superuser password     |
| `<namespace>_postgres-primary-password`    | Postgres primary password    |
| `<namespace>_postgres-replica-password`    | Postgres replic password    |
| `<namespace>_tls-certificates`    | TLS Certificate and Key for the domain you will be accessing your instance at in `.pem` format    |

#### Service Account

A Service Account is required for successful deployment of your instance. This Service Account is used internally to provide access to the above configured Secrets.

The default name for you Service Account should be `clearblade-gsm-read`. If you want to use a different name for any reason you will need to update this in your values.yaml file, as well as the install command.

This Service Account is required to have the following Roles:

- Secret Manager Secret Accessor

### Configuration & Installation

After all above resources exists, using the `gke-default-values.yaml` as a starting point, update all configuration values for your specific environment. Note that values for the imagePullerSecret and instance ID will be provided by ClearBlade.

Finally, after connecting to your GKE cluster using the gcloud cli, you will be able to install your instance using the following command, replacing values inside the curly braces to match your environment:

```
helm install clearblade-iot-enterprise https://github.com/ClearBlade/helm-charts/releases/download/clearblade-iot-enterprise-2.13.6/clearblade-iot-enterprise-2.13.6.tgz -f ./my-values.yaml && gcloud --project={gcp project id} iam service-accounts add-iam-policy-binding clearblade-gsm-read@{gcp project id}.iam.gserviceaccount.com --role roles/iam.workloadIdentityUser --member "serviceAccount:{gcp project id}.svc.id.goog[{kubernetes namespace}/clearblade-gsm-read]"
```

# ClearBlade Monitoring

The `clearblade-monitoring` Helm chart is a secondary deployment used to monitor your enterprise instance. To install in your own Kubernetes cluster please use the `gke-default-monitoring-values.yaml` file in this repo for configuring this instance. This includes the basic configurations required for installing into a normal Kubernetes environment.

## GMP

This helm chart is configurable to use either Google Managed Prometheus or a standard Prometheus deployment(reccomended). Be sure that the global value 'GMP' is the same for both monitoring and iot-enterprise deployments in order to ensure the proper exporters and scrape configurations are deployed. Unless you choose to use a Google Managed Prometheus instance, leave GMP set to the default 'false'.

### Required Resources

#### IP Addresses

For monitoring you will need 1 static public IP address provisioned to allow access to your Prometheus and optional Grafana instance from the public internet. This IP address should be created in the same Region as your GKE Cluster.

#### Secrets

You will need one secret, `<monitoring-namespace>_tls-certificates`, containing the TLS Certificate and Key for the monitoring domain you will be accessing your instance at in `.pem` format.

#### Service Account

You will need the same service account credentials as your enterprise deployment. You may reuse that service account for monitoring.

#### Disk

If you are not using GMP, it is reccomended to create a disk for your prometheus data. This is optional, but to use simply include the name of the disk and its size in your monitoring-values yaml file. Create your disk with the following specs

Type: Regional SSD Persistent Disk   
Zones: Must match the 2 zones configured in the GKE cluster  
Snapshots: Enabled at your preferred schedule for backup purposes 

### Configuration & Installation

After all above resources exists, using the `gke-default-monitoring-values.yaml` as a starting point, update all configuration values for your specific environment.

Finally, after connecting to your GKE cluster using the gcloud cli, you will be able to install your monitoring instance using the following command, replacing values inside the curly braces to match your environment (the following assumes your monitoring namespace is simply named monitoring):

```
helm install clearblade-monitoring https://github.com/ClearBlade/helm-charts/releases/download/clearblade-monitoring-2.13.4/clearblade-monitoring-2.13.3.tgz -f ./my-monitoring-values.yaml && gcloud --project={gcp project id} iam service-accounts add-iam-policy-binding clearblade-gsm-read@{gcp project id}.iam.gserviceaccount.com --role roles/iam.workloadIdentityUser --member "serviceAccount:{gcp project id}.svc.id.goog[monitoring/clearblade-gsm-read]" && kubectl annotate serviceaccount clearblade-gsm-read     --namespace=monitoring     iam.gke.io/gcp-service-account=clearblade-gsm-read@{gcp project id}-os.iam.gserviceaccount.com

```


# Blue Green updates

## About

This document describes how to update your ClearBlade platform version in a blue/green style to prevent downtime and forced disconnects. It involves adding new ClearBlade pods/containers to your cluster, running the desired version, and having a transitional period while devices naturally reconnect to the newer pods. This comes at the cost of time and compute but should involve no service interruptions.

In our Kubernetes deployments, traffic is routed from the load balancer to ClearBlade through a Kubernetes service. By using labels in Kubernetes, we can limit the scope of this service to ClearBlade pods running only the desired version. Existing connections will persist, while new connections will only be established with the new ClearBlade version. Eventually, all devices will be connected to the new pods, and you can remove the existing pods.

## Requirements

Helm charts version 3.13.6 or newer

ClearBlade version 9.34.0 or newer (before update)

The following versions are unskippable - meaning you cannot jump from a prior version to a later version in a blue green fashion, without first updating to these versions (i.e. you cannot go directly from 9.34.1 to 9.34.3)

9.34.0

9.34.2

## Steps

These steps assume a blue-to-green transition. To transition from green back to blue for a second update, replace instances of 'global.enterprise.greenVersion' with 'global.enterprise.version' and instances of 'clearblade.greenReplicas' with 'clearblade.replicas' and vice versa. The replica and version values are applied to the blue pod set but are not explicitly named blue. For step 3, change the slot value to blue instead of green.

In your values file used to deploy ClearBlade with helm, set 'global.enterprise.greenVersion' to the platform version you want to upgrade to. Then, in the ClearBlade section, set 'clearblade.greenReplicas' to the desired number of pods.

Run 

'helm upgrade <deployment name> -f <path to values file> <path to clearblade-iot-enterprise tgz file>'

This will start your green pod set running the desired version. Wait for them to run, and optionally wait for them to finish autobalancing (see logs).

A useful helm plugin is helm-diff. With it installed, you can run the above command with ‘diff’ added (helm diff upgrade ….). This will not upgrade your deployment but instead show you the changes that will be made so you can be sure you are only making intended changes.

Update your values file to set 'global.enterprise.slot' to 'green'. If not set, this value defaults to blue.

Run the upgrade command above again. This will update your clearblade-service to route new connections to the new green set of ClearBlade pods instead of the existing old set. Before updating the service, your green pods must be running to establish new connections immediately.

You are now in a transitional state and running two versions of ClearBlade simultaneously. Existing connections to the old ClearBlade set will persist while new connections connect to the new set. Stay in this state until all devices have reconnected to the new set for minimal interruption.

You may change the 'clearblade.replicas' value to 0, run the upgrade command, and exclusively run the new version and be done with your update.





