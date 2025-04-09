#!/bin/bash

#############################################################
# TimescaleDB Purge Script for Kubernetes
#############################################################
# 
# Purpose: This script automates purging data from TimescaleDB 
# in a Kubernetes environment. It's useful when you need to:
#   - Clear out accumulated IoT sensor data
#   - Reset your database for testing
#   - Reclaim disk space without destroying database structure
#   - Troubleshoot performance issues due to large datasets
#
# The script automatically finds your TimescaleDB pod,
# extracts credentials, and purges all data while preserving
# table structures.
#
# Usage: ./purgedb.sh

set -e  # Exit on any error

echo "🔍 Finding TimescaleDB pod..."
NAMESPACE=$(kubectl get pods --all-namespaces | grep timescale | awk '{print $1}')
POD_NAME=$(kubectl get pods --all-namespaces | grep timescale | awk '{print $2}')

if [ -z "$POD_NAME" ]; then
    echo "❌ Error: No TimescaleDB pod found"
    exit 1
fi

echo "✓ Found TimescaleDB pod: $POD_NAME in namespace: $NAMESPACE"

echo "🔑 Retrieving database credentials..."
SECRET_DATA=$(kubectl get secret -n $NAMESPACE db-credentials -o yaml)

DB_NAME=$(echo "$SECRET_DATA" | grep POSTGRES_DB | awk '{print $2}' | base64 --decode)
DB_USER=$(echo "$SECRET_DATA" | grep POSTGRES_USER | awk '{print $2}' | base64 --decode)
DB_PASS=$(echo "$SECRET_DATA" | grep POSTGRES_PASSWORD | awk '{print $2}' | base64 --decode)

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
    echo "❌ Error: Could not retrieve database credentials"
    exit 1
fi

echo "✓ Retrieved credentials for database: $DB_NAME"

echo "📊 Checking database structure..."
TABLES=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- psql -U $DB_USER -d $DB_NAME -c "\dt" -t | awk '{print $3}')

if [ -z "$TABLES" ]; then
    echo "❓ No tables found or error retrieving tables"
    exit 1
fi

# Convert multiline output to space-separated list
TABLES=$(echo $TABLES | tr '\n' ' ')
echo "✓ Found tables: $TABLES"

# Main purge operation
echo "🧹 Purging data..."
for TABLE in $TABLES; do
    echo "   Purging table: $TABLE"
    kubectl exec -it -n $NAMESPACE $POD_NAME -- psql -U $DB_USER -d $DB_NAME -c "TRUNCATE $TABLE;"
    if [ $? -eq 0 ]; then
        echo "   ✓ Successfully purged $TABLE"
    else
        echo "   ❌ Failed to purge $TABLE"
    fi
done

echo "✅ Database purge complete!"
