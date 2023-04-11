#!/bin/bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
readonly APPS_ROOT="${PROJECT_ROOT}/apps"

SUFFIX='-pr'

if [ -z "SUFFIX" ]; then SUFFIX=$(openssl rand -hex 3); else echo $SUFFIX; fi

echo "The service suffix for this installation: $SUFFIX"

readonly REDIS_NAME="fitness-cache${SUFFIX}"
readonly ORDER_SERVICE_POSTGRES_CONNECTION="order_service_db"
readonly CART_SERVICE_REDIS_CONNECTION="cart_service_cache"
readonly CATALOG_SERVICE_DB_CONNECTION="catalog_service_db"
readonly ACMEFIT_CATALOG_DB_NAME="acmefit_catalog"
readonly ACMEFIT_ORDER_DB_NAME="acmefit_order"
readonly ACMEFIT_POSTGRES_DB_PASSWORD="Acm3F!tness"
readonly ACMEFIT_POSTGRES_DB_USER=dbadmin
readonly ACMEFIT_POSTGRES_SERVER="acmefitnessdb-demo${SUFFIX}"
readonly ORDER_DB_NAME="orders"
readonly CART_SERVICE="cart-service"
readonly IDENTITY_SERVICE="identity-service"
readonly ORDER_SERVICE="order-service"
readonly PAYMENT_SERVICE="payment-service"
readonly CATALOG_SERVICE="catalog-service"
readonly FRONTEND_APP="frontend"
readonly CUSTOM_BUILDER="no-bindings-builder"
readonly CURRENT_USER=$(az account show --query user.name -o tsv)
TEMP_USER_ID=$(az ad user show --id $CURRENT_USER --query id -o tsv)
if [ -n $TEMP_USER_ID ]; then
  readonly CURRENT_USER_OBJECTID=$TEMP_USER_ID
else
  readonly CURRENT_USER_OBJECTID=$(az ad user show --id $CURRENT_USER --query objectId -o tsv)
fi

if [ -z $CURRENT_USER_OBJECTID ]; then
  echo "Unable to get current user object id"
  exit 1
fi

readonly CONFIG_REPO=https://github.com/Azure-Samples/acme-fitness-store-config

RESOURCE_GROUP="rg-acme-fitness${SUFFIX}"
SPRING_APPS_SERVICE="spring-acme-fitness${SUFFIX}"
readonly AZURE_AD_APP_NAME="acme-fitness${SUFFIX}"
REGION='eastus'

function create_spring_cloud() {
  az group create --name ${RESOURCE_GROUP} \
    --location ${REGION}

  az provider register --namespace Microsoft.SaaS
  az term accept --publisher vmware-inc --product azure-spring-cloud-vmware-tanzu-2 --plan tanzu-asc-ent-mtr

  az spring create --name ${SPRING_APPS_SERVICE} \
    --resource-group ${RESOURCE_GROUP} \
    --location ${REGION} \
    --sku Enterprise \
    --enable-application-configuration-service \
    --enable-service-registry \
    --enable-gateway \
    --enable-api-portal

}

function configure_defaults() {
  echo "Configure azure defaults resource group: $RESOURCE_GROUP and spring $SPRING_APPS_SERVICE"
  az configure --defaults group=$RESOURCE_GROUP spring=$SPRING_APPS_SERVICE location=${REGION}
}

function create_dependencies() {
  echo "Creating Azure Cache for Redis Instance $REDIS_NAME in location ${REGION}"
  az redis create --location $REGION --name $REDIS_NAME --resource-group $RESOURCE_GROUP --sku Basic --vm-size c0

  echo "Creating Azure Database for Postgres $ACMEFIT_POSTGRES_SERVER"
  # create postgresql flexible server
  az postgres flexible-server create \
    --name $ACMEFIT_POSTGRES_SERVER \
    --resource-group $RESOURCE_GROUP \
    --location $REGION \
    --admin-user $ACMEFIT_POSTGRES_DB_USER \
    --admin-password $ACMEFIT_POSTGRES_DB_PASSWORD \
    --public-access 0.0.0.0 \
    --tier Burstable \
    --sku-name Standard_B1ms \
    --version 14 \
    --storage-size 32

  # activate ad autentication
  echo "Activating AD authentication on $ACMEFIT_POSTGRES_SERVER"
  az postgres flexible-server parameter set \
    --server-name ${ACMEFIT_POSTGRES_SERVER} \
    --resource-group ${RESOURCE_GROUP} \
    --name azure.extensions \
    --value uuid-ossp

  echo "Creating Postgres Database $ACMEFIT_CATALOG_DB_NAME"
  az postgres flexible-server db create \
    -g $RESOURCE_GROUP \
    -s $ACMEFIT_POSTGRES_SERVER \
    -d $ACMEFIT_CATALOG_DB_NAME

  echo "Creating Postgres Database $ACMEFIT_ORDER_DB_NAME"
  az postgres flexible-server db create \
    -g $RESOURCE_GROUP \
    -s $ACMEFIT_POSTGRES_SERVER \
    -d $ACMEFIT_ORDER_DB_NAME
}

function create_builder() {
  echo "Creating a custom builder with name $CUSTOM_BUILDER and configuration $PROJECT_ROOT/azure/builder.json"
  az spring build-service builder create -n $CUSTOM_BUILDER --builder-file "$PROJECT_ROOT/azure/builder.json"
}

function configure_sso() {
  echo "Configuring SSO"
  az ad app create --display-name ${AZURE_AD_APP_NAME} >ad.json
  export APPLICATION_ID=$(cat ad.json | jq -r '.appId')

  az ad app credential reset --id ${APPLICATION_ID} --append >sso.json
  az ad sp create --id ${APPLICATION_ID}

  source ./setup-sso-variables-ad.sh
}

function configure_gateway() {
  az spring gateway update --assign-endpoint true
  local gateway_url=$(az spring gateway show | jq -r '.properties.url')

  source ./setup-sso-variables-ad.sh
  echo "Configuring Spring Cloud Gateway"
  az spring gateway update \
    --api-description "ACME Fitness API" \
    --api-title "ACME Fitness" \
    --api-version "v.01" \
    --server-url "https://$gateway_url" \
    --allowed-origins "*" \
    --client-id ${CLIENT_ID} \
    --client-secret ${CLIENT_SECRET} \
    --scope "openid,profile" \
    --issuer-uri ${ISSUER_URI}
}

function update_sso_portalurl() {
  source ./setup-sso-variables-ad.sh

  APPLICATION_ID=$(cat ad.json | jq -r '.appId')
  local gateway_url=$(az spring gateway show | jq -r '.properties.url')
  local portal_url=$(az spring api-portal show | jq -r '.properties.url')

  reply_urls="https://${gateway_url}/login/oauth2/code/sso"
  if [ -n "$portal_url" ]; then
    reply_urls="${reply_urls} https://${portal_url}/oauth2-redirect.html" "https://${portal_url}/login/oauth2/code/sso"
  fi

  az ad app update --id ${APPLICATION_ID} \
    --web-redirect-uris ${reply_urls}
}

function configure_acs() {
  echo "Configuring Application Configuration Service to use repo: ${CONFIG_REPO}"
  az spring application-configuration-service git repo add --name acme-config --label main --patterns "catalog,identity,payment" --uri ${CONFIG_REPO}
}

function create_cart_service() {
  echo "Creating cart-service app"
  az spring app create --name $CART_SERVICE
  az spring gateway route-config create --name $CART_SERVICE --app-name $CART_SERVICE --routes-file "$PROJECT_ROOT/azure/routes/cart-service.json"

  az spring connection create redis \
    --service $SPRING_APPS_SERVICE \
    --deployment default \
    --resource-group $RESOURCE_GROUP \
    --target-resource-group $RESOURCE_GROUP \
    --server $REDIS_NAME \
    --database 0 \
    --app $CART_SERVICE \
    --client-type java \
    --connection $CART_SERVICE_REDIS_CONNECTION
}

function create_identity_service() {
  echo "Creating identity service"
  az spring app create --name $IDENTITY_SERVICE
  az spring application-configuration-service bind --app $IDENTITY_SERVICE
  az spring gateway route-config create --name $IDENTITY_SERVICE --app-name $IDENTITY_SERVICE --routes-file "$PROJECT_ROOT/azure/routes/identity-service.json"
}

function create_order_service() {
  echo "Creating order service"
  az spring app create --name $ORDER_SERVICE
  az spring gateway route-config create --name $ORDER_SERVICE --app-name $ORDER_SERVICE --routes-file "$PROJECT_ROOT/azure/routes/order-service.json"

  az spring connection create postgres-flexible \
    --resource-group $RESOURCE_GROUP \
    --service $SPRING_APPS_SERVICE \
    --connection $ORDER_SERVICE_POSTGRES_CONNECTION \
    --app $ORDER_SERVICE \
    --deployment default \
    --tg $RESOURCE_GROUP \
    --server $ACMEFIT_POSTGRES_SERVER \
    --database $ACMEFIT_ORDER_DB_NAME \
    --secret name=${ACMEFIT_POSTGRES_DB_USER} secret=${ACMEFIT_POSTGRES_DB_PASSWORD} \
    --client-type dotnet
}

function create_catalog_service() {
  echo "Creating catalog service"
  az spring app create --name $CATALOG_SERVICE
  az spring application-configuration-service bind --app $CATALOG_SERVICE
  az spring service-registry bind --app $CATALOG_SERVICE
  az spring gateway route-config create --name $CATALOG_SERVICE --app-name $CATALOG_SERVICE --routes-file "$PROJECT_ROOT/azure/routes/catalog-service.json"

  az spring connection create postgres-flexible \
    --resource-group $RESOURCE_GROUP \
    --service $SPRING_APPS_SERVICE \
    --connection $CATALOG_SERVICE_DB_CONNECTION \
    --app $CATALOG_SERVICE \
    --deployment default \
    --tg $RESOURCE_GROUP \
    --server $ACMEFIT_POSTGRES_SERVER \
    --database $ACMEFIT_CATALOG_DB_NAME \
    --client-type springboot \
    --system-identity
}

function create_payment_service() {
  echo "Creating payment service"
  az spring app create --name $PAYMENT_SERVICE
  az spring application-configuration-service bind --app $PAYMENT_SERVICE
  az spring service-registry bind --app $PAYMENT_SERVICE
}

function create_frontend_app() {
  echo "Creating frontend"
  az spring app create --name $FRONTEND_APP
  az spring gateway route-config create --name $FRONTEND_APP --app-name $FRONTEND_APP --routes-file "$PROJECT_ROOT/azure/routes/frontend.json"
}

function deploy_cart_service() {
  echo "Deploying cart-service application"
  local redis_conn_str=$(az spring connection show -g $RESOURCE_GROUP \
    --service $SPRING_APPS_SERVICE \
    --deployment default \
    --app $CART_SERVICE \
    --connection $CART_SERVICE_REDIS_CONNECTION | jq -r '.configurations[0].value')
  local gateway_url=$(az spring gateway show | jq -r '.properties.url')
  local app_insights_key=$(az spring build-service builder buildpack-binding show -n default | jq -r '.properties.launchProperties.properties."connection-string"')

  az spring app deploy --name $CART_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "CART_PORT=8080" "REDIS_CONNECTIONSTRING=$redis_conn_str" "AUTH_URL=https://${gateway_url}" "INSTRUMENTATION_KEY=$app_insights_key" \
    --source-path "$APPS_ROOT/acme-cart"
}

function deploy_identity_service() {
  source ./setup-sso-variables-ad.sh
  echo "Deploying identity-service application"
  az spring app deploy --name $IDENTITY_SERVICE \
    --env "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI=${JWK_SET_URI}" \
    --config-file-pattern identity \
    --jvm-options='-XX:MaxMetaspaceSize=148644K' \
    --source-path "$APPS_ROOT/acme-identity"
}

function deploy_order_service() {
  echo "Deploying user-service application"
  local gateway_url=$(az spring gateway show | jq -r '.properties.url')
  local postgres_connection_url=$(az spring connection show -g $RESOURCE_GROUP \
    --service $SPRING_APPS_SERVICE \
    --deployment default \
    --connection $ORDER_SERVICE_POSTGRES_CONNECTION \
    --app $ORDER_SERVICE | jq '.configurations[0].value' -r)
  local app_insights_key=$(az spring build-service builder buildpack-binding show -n default | jq -r '.properties.launchProperties.properties."connection-string"')

  az spring app deploy --name $ORDER_SERVICE \
    --builder $CUSTOM_BUILDER \
    --env "DatabaseProvider=Postgres" "ConnectionStrings__OrderContext=$postgres_connection_url" "AcmeServiceSettings__AuthUrl=https://${gateway_url}" "ApplicationInsights__ConnectionString=$app_insights_key" \
    --source-path "$APPS_ROOT/acme-order"
}

function deploy_catalog_service() {
  echo "Building catalog-service application"
  CURRENT_DIR=$(pwd)
  cd "$APPS_ROOT/acme-catalog"
  $APPS_ROOT/acme-catalog/gradlew clean build
  cd $CURRENT_DIR

  echo "Deploying catalog-service application"
  az spring app deploy --name $CATALOG_SERVICE \
    --config-file-pattern catalog \
    --jvm-options='-XX:MaxMetaspaceSize=148644K' \
    --source-path "$APPS_ROOT/acme-catalog" \
    --env "SPRING_DATASOURCE_AZURE_PASSWORDLESSENABLED=true"
}

function deploy_payment_service() {
  echo "Deploying payment-service application"

  az spring app deploy --name $PAYMENT_SERVICE \
    --config-file-pattern payment \
    --jvm-options='-XX:MaxMetaspaceSize=148644K' \
    --source-path "$APPS_ROOT/acme-payment"
}

function deploy_frontend_app() {
  echo "Deploying frontend application"
  local app_insights_key=$(az spring build-service builder buildpack-binding show -n default | jq -r '.properties.launchProperties.properties."connection-string"')

  rm -rf "$APPS_ROOT/acme-shopping/node_modules"
  az spring app deploy --name $FRONTEND_APP \
    --builder $CUSTOM_BUILDER \
    --env "APPLICATIONINSIGHTS_CONNECTION_STRING=$app_insights_key" \
    --source-path "$APPS_ROOT/acme-shopping"
}

function main() {
  create_spring_cloud
  configure_defaults
  create_dependencies
  create_builder
  configure_acs
  configure_sso
  configure_gateway

  create_identity_service
  create_cart_service
  create_order_service
  create_payment_service
  create_catalog_service
  create_frontend_app

  deploy_identity_service
  deploy_cart_service
  deploy_order_service
  deploy_payment_service
  deploy_catalog_service
  deploy_frontend_app

  update_sso_portalurl

}

function usage() {
  echo 1>&2
  echo "Usage: $0 -g <resource_group> -s <SPRING_APPS_SERVICE>" 1>&2
  echo 1>&2
  echo "Options:" 1>&2
  echo "  -g <namespace>            the Azure resource group to use for the deployment" 1>&2
  echo "  -r <region>               the Azure region to use for the deployment" 1>&2
  echo "  -s <SPRING_APPS_SERVICE>  the name of the Azure Spring Apps Instance to use" 1>&2
  echo 1>&2
  exit 1
}

function check_args() {
  if [[ -z $RESOURCE_GROUP ]]; then
    echo "Provide a valid resource group with -g"
    usage
  fi

  if [[ -z $SPRING_APPS_SERVICE ]]; then
    echo "Provide a valid spring cloud instance name with -s"
    usage
  fi

  if [[ -z $REGION ]]; then
    echo "Provide a valid region with -r"
    usage
  fi
}

while getopts ":g:s:r:" options; do
  case "$options" in
  g)
    RESOURCE_GROUP="$OPTARG"
    ;;
  s)
    SPRING_APPS_SERVICE="$OPTARG"
    ;;
  r)
    REGION="$OPTARG"
    ;;
  *)
    usage
    exit 1
    ;;
  esac

  case $OPTARG in
  -*)
    echo "Option $options needs a valid argument"
    exit 1
    ;;
  esac
done

check_args
main
