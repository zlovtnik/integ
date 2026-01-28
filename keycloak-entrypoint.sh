#!/bin/bash

# Entrypoint script for Keycloak to enforce production TLS requirements

if [ "$1" = "start" ]; then
  if [ -z "$KC_HOSTNAME" ] || [ -z "$KC_HTTPS_CERTIFICATE_FILE" ] || [ -z "$KC_HTTPS_CERTIFICATE_KEY_FILE" ]; then
    echo "Error: Production mode (start) requires KC_HOSTNAME, KC_HTTPS_CERTIFICATE_FILE, and KC_HTTPS_CERTIFICATE_KEY_FILE to be set"
    exit 1
  fi
fi

# Execute the original Keycloak entrypoint
exec /opt/keycloak/bin/kc.sh "$@"