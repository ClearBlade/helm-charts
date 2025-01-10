#!/bin/bash
set -e
export SCALE_NUMBER=`echo $HOSTNAME | awk 'BEGIN { FS = "-"} ; {print $NF}'`
export POSTGRES_SERVICE=`echo $HOSTNAME | awk 'BEGIN {FS=OFS="-"} {$NF=""; NF--; print}'`

if [ $SCALE_NUMBER -ne "0" ]; then
  echo "Running database as REPLICA"
  if [ -s "/var/lib/postgresql/data/clearblade/PG_VERSION" ]; then
    echo "Database replica already exists."
  else
    export NAMESPACE=`cat /var/run/secrets/kubernetes.io/serviceaccount/namespace`
    export PGPASSWORD=$REPLICA_PASSWORD

    echo "Creating backup from master in namespace: $NAMESPACE"
    echo "pg_basebackup -D /var/lib/postgresql/data/clearblade -h $POSTGRES_SERVICE-0.$POSTGRES_SERVICE-headless.$NAMESPACE.svc.cluster.local -X stream -c fast -U $REPLICA_USER -R"
    pg_basebackup -D /var/lib/postgresql/data/clearblade -h $POSTGRES_SERVICE-0.$POSTGRES_SERVICE-headless.$NAMESPACE.svc.cluster.local -X stream -c fast -U $REPLICA_USER -R
  fi
else
  echo "Running database as PRIMARY"
fi
echo "Starting database"
docker-entrypoint.sh -c config_file=/etc/postgresql/postgresql.conf
