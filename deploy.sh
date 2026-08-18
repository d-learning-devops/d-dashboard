#!/usr/bin/env bash
# =====================================================================
# Self-Hosted Grafana on Azure Container Apps — POC deploy script
# Fleet Cart Ops monitoring demo
#
# What this does, top to bottom:
#   1. Creates a resource group
#   2. Creates a Log Analytics workspace (required by Container Apps env)
#   3. Creates the Container Apps Environment
#   4. Creates a Storage Account + File Share for Grafana's persistent data
#      (dashboards, plugins, sqlite db, provisioning files)
#   5. Uploads the datasource provisioning file (Azure Monitor + Infinity)
#   6. Registers that File Share as environment storage
#   7. Deploys Grafana OSS as a Container App, mounted to that storage,
#      with the Infinity plugin auto-installed and a system-assigned
#      managed identity for Azure Monitor auth
#   8. Grants that identity "Monitoring Reader" so it can read metrics
#      from your existing Container Apps / SAP resources
#   9. Prints the public URL to log in and demo from
#
# Prereqs: az cli logged in (`az login`), containerapp extension,
# an active subscription selected (`az account set --subscription <id>`)
# =====================================================================
set -euo pipefail

# ---------- 0. Variables — edit these for your environment ----------
RG="rg-fleetcart-grafana-poc"
LOCATION="centralindia"                 # nearest region; change if needed
LAW_NAME="law-fleetcart-poc"
CAE_NAME="cae-fleetcart-poc"
STORAGE_ACCOUNT="stfleetcartgrafana$RANDOM"   # must be globally unique
FILE_SHARE="grafana-data"
STORAGE_MOUNT_NAME="grafana-storage"
GRAFANA_APP="grafana-poc"
GRAFANA_IMAGE="grafana/grafana-oss:11.2.0"
ADMIN_USER="admin"
ADMIN_PASSWORD="$(openssl rand -base64 12)"    # random, printed at the end

echo "==> Using resource group: $RG in $LOCATION"
echo "==> Generated Grafana admin password (save this): $ADMIN_PASSWORD"

# ---------- 1. Resource group ----------
az group create \
  --name "$RG" \
  --location "$LOCATION" \
  --output none

# ---------- 2. Log Analytics workspace ----------
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --output none

LAW_CLIENT_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

LAW_CLIENT_SECRET=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --query primarySharedKey -o tsv)

# ---------- 3. Container Apps Environment ----------
az extension add --name containerapp --upgrade --yes 2>/dev/null || true
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait

az containerapp env create \
  --name "$CAE_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --logs-workspace-id "$LAW_CLIENT_ID" \
  --logs-workspace-key "$LAW_CLIENT_SECRET" \
  --output none

# ---------- 4. Storage account + file share for Grafana persistence ----------
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

STORAGE_KEY=$(az storage account keys list \
  --resource-group "$RG" --account-name "$STORAGE_ACCOUNT" \
  --query "[0].value" -o tsv)

az storage share create \
  --name "$FILE_SHARE" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --output none

# Sub-directories Grafana's image expects for provisioning
az storage directory create --share-name "$FILE_SHARE" --name "provisioning" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" --output none
az storage directory create --share-name "$FILE_SHARE" --name "provisioning/datasources" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" --output none
az storage directory create --share-name "$FILE_SHARE" --name "provisioning/dashboards" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" --output none

# ---------- 5. Upload provisioning files (datasources + starter dashboard) ----------
az storage file upload \
  --share-name "$FILE_SHARE" \
  --source "./provisioning/datasources.yaml" \
  --path "provisioning/datasources/datasources.yaml" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --output none

az storage file upload \
  --share-name "$FILE_SHARE" \
  --source "./provisioning/dashboards.yaml" \
  --path "provisioning/dashboards/dashboards.yaml" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --output none

az storage file upload \
  --share-name "$FILE_SHARE" \
  --source "./provisioning/fleetcart-overview.json" \
  --path "provisioning/dashboards/fleetcart-overview.json" \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --output none

# ---------- 6. Register the file share as Container Apps environment storage ----------
az containerapp env storage set \
  --name "$CAE_NAME" \
  --resource-group "$RG" \
  --storage-name "$STORAGE_MOUNT_NAME" \
  --azure-file-account-name "$STORAGE_ACCOUNT" \
  --azure-file-account-key "$STORAGE_KEY" \
  --azure-file-share-name "$FILE_SHARE" \
  --access-mode ReadWrite \
  --output none

# ---------- 7. Deploy Grafana as a Container App ----------
az containerapp create \
  --name "$GRAFANA_APP" \
  --resource-group "$RG" \
  --environment "$CAE_NAME" \
  --image "$GRAFANA_IMAGE" \
  --target-port 3000 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 1 \
  --cpu 0.5 --memory 1.0Gi \
  --system-assigned \
  --secrets "grafana-admin-password=$ADMIN_PASSWORD" \
  --env-vars \
      "GF_SECURITY_ADMIN_USER=$ADMIN_USER" \
      "GF_SECURITY_ADMIN_PASSWORD=secretref:grafana-admin-password" \
      "GF_INSTALL_PLUGINS=yesoreyeram-infinity-datasource,grafana-azure-monitor-datasource" \
      "GF_AZURE_MANAGED_IDENTITY_ENABLED=true" \
      "GF_PATHS_PROVISIONING=/var/lib/grafana/provisioning" \
  --output none

# Mount the file share into the running app (min replicas 1 = SQLite-safe for a POC;
# don't scale this past 1 replica without moving Grafana to a Postgres backend)
az containerapp update \
  --name "$GRAFANA_APP" \
  --resource-group "$RG" \
  --output none

# Attach the volume + mount via a YAML patch (az containerapp create doesn't do
# azure-file volumes inline, so we patch it here)
cat > /tmp/grafana-volume-patch.yaml <<EOF
properties:
  template:
    volumes:
      - name: grafana-data-vol
        storageType: AzureFile
        storageName: $STORAGE_MOUNT_NAME
    containers:
      - name: $GRAFANA_APP
        volumeMounts:
          - volumeName: grafana-data-vol
            mountPath: /var/lib/grafana
EOF

az containerapp update \
  --name "$GRAFANA_APP" \
  --resource-group "$RG" \
  --yaml /tmp/grafana-volume-patch.yaml \
  --output none

# ---------- 8. Grant Grafana's managed identity read access to Azure Monitor ----------
PRINCIPAL_ID=$(az containerapp show \
  --name "$GRAFANA_APP" --resource-group "$RG" \
  --query identity.principalId -o tsv)

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Monitoring Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
  --output none

# ---------- 9. Output ----------
FQDN=$(az containerapp show \
  --name "$GRAFANA_APP" --resource-group "$RG" \
  --query properties.configuration.ingress.fqdn -o tsv)

echo ""
echo "======================================================================"
echo " Grafana POC is deploying. First boot can take 1-2 minutes."
echo ""
echo "   URL:      https://$FQDN"
echo "   User:     $ADMIN_USER"
echo "   Password: $ADMIN_PASSWORD"
echo ""
echo " Next: log in, then add your GitHub token / Cloudflare token as"
echo " Infinity datasource auth (see README.md step 5)."
echo "======================================================================"
