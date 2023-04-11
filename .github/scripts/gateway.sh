#!/bin/bash

set -euxo pipefail

: "${RESOURCE_GROUP:?'must be set'}"
: "${SPRING_APPS_SERVICE:?'must be set'}"
: "${IDENTITY_SERVICE_APP:?'must be set'}"
: "${CART_SERVICE_APP:?'must be set'}"
: "${ORDER_SERVICE_APP:?'must be set'}"
: "${CATALOG_SERVICE_APP:?'must be set'}"
: "${FRONTEND_APP:?'must be set'}"

update_route_config() {
  local config_names=$1
  local config_name=$2
  local config_file=$3

  az spring gateway route-config update \
    --name "$config_name" \
    --app-name "$config_name" \
    --routes-file "$config_file"
}

main() {
  local gateway_url config_names

  az configure --defaults group="$RESOURCE_GROUP" spring="$SPRING_APPS_SERVICE"

  gateway_url=$(az spring gateway show | jq -r '.properties.url')

  az spring gateway update \
    --server-url "https://$gateway_url" \

  update_route_config "$IDENTITY_SERVICE_APP" "$IDENTITY_SERVICE_APP" identity-service.json
  update_route_config "$CART_SERVICE_APP" "$CART_SERVICE_APP" cart-service.json
  update_route_config "$ORDER_SERVICE_APP" "$ORDER_SERVICE_APP" order-service.json
  update_route_config "$CATALOG_SERVICE_APP" "$CATALOG_SERVICE_APP" catalog-service.json
  update_route_config "$FRONTEND_APP" "$FRONTEND_APP" frontend.json

}

main
