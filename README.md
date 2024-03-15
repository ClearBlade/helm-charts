# helm-charts
Repository for helm charts to deploy the ClearBlade IoT Enterprise platform and monitoring

# ClearBlade IoT Enterprise

The `clearblade-iot-enterprise` Helm chart enables you install an instance of the platform in your own infrastructure. The Helm charts support installing in your own Kubernetes environment, or within Google Cloud.

## Kubernetes

To install in your own Kubernetes cluster please use the `default-values.yaml` file in this repo for configuring this instance. This includes the basic configurations required for installing into a normal Kubernetes environment.

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
helm install clearblade-iot-enterprise https://github.com/ClearBlade/helm-charts/releases/download/clearblade-iot-enterprise-2.13.3/clearblade-iot-enterprise-2.13.3.tgz -f ./my-values.yaml && gcloud --project={gcp project id} iam service-accounts add-iam-policy-binding clearblade-gsm-read@{gcp project id}.iam.gserviceaccount.com --role roles/iam.workloadIdentityUser --member "serviceAccount:{gcp project id}.svc.id.goog[{kubernetes namespace}/clearblade-gsm-read]"
```

# ClearBlade Monitoring
