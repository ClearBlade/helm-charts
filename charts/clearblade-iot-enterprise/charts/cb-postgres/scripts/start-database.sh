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
docker-entrypoint.sh -c config_file=/etc/postgresql/postgresql.conf &
PG_PID=$!

if [ $SCALE_NUMBER -eq "0" ]; then
  echo "Waiting for PostgreSQL to become ready..."
  until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q; do
    sleep 1
  done

  echo "Ensuring database setup is up to date..."
  psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$PRIMARY_USER') THEN
        CREATE USER $PRIMARY_USER;
      END IF;
    END
    \$\$;
    ALTER USER $PRIMARY_USER WITH SUPERUSER;
    ALTER USER $PRIMARY_USER WITH PASSWORD '$PRIMARY_PASSWORD';
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICA_USER') THEN
        CREATE USER $REPLICA_USER REPLICATION LOGIN ENCRYPTED PASSWORD '$REPLICA_PASSWORD';
      ELSE
        ALTER USER $REPLICA_USER WITH REPLICATION LOGIN ENCRYPTED PASSWORD '$REPLICA_PASSWORD';
      END IF;
    END
    \$\$;
    SELECT 'CREATE DATABASE admin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'admin')\gexec
    GRANT ALL PRIVILEGES ON DATABASE admin TO $PRIMARY_USER;

EOSQL

  echo "Installing extensions in admin database..."
  psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "admin" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE EXTENSION IF NOT EXISTS timescaledb;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS pgstattuple;
    GRANT EXECUTE ON FUNCTION pgstattuple_approx(regclass) TO $PRIMARY_USER;
    GRANT EXECUTE ON FUNCTION pgstatindex(regclass) TO $PRIMARY_USER;
    GRANT EXECUTE ON FUNCTION pgstatginindex(regclass) TO $PRIMARY_USER;
EOSQL

  if [ "$ENABLE_DOWNSAMPLING" = "true" ]; then
    echo "Installing downsampling extension..."
    psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "admin" <<-EOSQL
      CREATE EXTENSION IF NOT EXISTS downsampling;
EOSQL
  fi

  echo "Database setup completed."
fi

wait $PG_PID
