#!/usr/bin/env bash
#
# Start an AWX controller service alongside the gateway dev environment.
# Requires: a running gateway dev environment (make podman-compose in aap-gateway)
#
# Usage:
#   ./tools/controller-dev-env/setup.sh          # start controller
#   ./tools/controller-dev-env/setup.sh teardown  # stop and clean up
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="awx_controller"
AWX_IMAGE="${AWX_IMAGE:-ghcr.io/ansible/awx:devel}"
AWX_DB_NAME="awx"
DB_CONTAINER="aap_gw_db_pgsql_1"
GW_CONTAINER="aap_gw_1"
AWX_PORT=8013
# Auto-detect gateway URL: try proxy (8443), then direct (8000)
if [[ -n "${GATEWAY_URL:-}" ]]; then
    :
elif curl -sf -k https://localhost:8443/api/gateway/v1/ping/ &>/dev/null; then
    GATEWAY_URL="https://localhost:8443"
elif curl -sf -k https://localhost:8000/api/gateway/v1/ping/ &>/dev/null; then
    GATEWAY_URL="https://localhost:8000"
else
    GATEWAY_URL="https://localhost:8443"
fi
GATEWAY_USERNAME="${GATEWAY_USERNAME:-admin}"
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-}"

# Detect gateway password from container-startup.yml if not set
if [[ -z "$GATEWAY_PASSWORD" ]]; then
    STARTUP_YML="${AAP_GATEWAY_DIR:-../aap-gateway}/container-startup.yml"
    if [[ -f "$STARTUP_YML" ]]; then
        GATEWAY_PASSWORD=$(awk '/gateway_admin_password/{gsub(/'\''/, ""); print $2}' "$STARTUP_YML")
    fi
    if [[ -z "$GATEWAY_PASSWORD" ]]; then
        echo "Error: GATEWAY_PASSWORD not set and could not detect from container-startup.yml"
        echo "Set GATEWAY_PASSWORD or AAP_GATEWAY_DIR environment variable"
        exit 1
    fi
fi

teardown() {
    echo "Tearing down controller environment..."
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    podman exec "$DB_CONTAINER" psql -U postgres -c "DROP DATABASE IF EXISTS $AWX_DB_NAME;" 2>/dev/null || true
    echo "Done."
}

if [[ "${1:-}" == "teardown" ]]; then
    teardown
    exit 0
fi

echo "=== Setting up AWX controller alongside gateway ==="

# 1. Check gateway is running
if ! podman inspect "$GW_CONTAINER" &>/dev/null; then
    echo "Error: Gateway container '$GW_CONTAINER' not running."
    echo "Start the gateway dev environment first (make podman-compose in aap-gateway)."
    exit 1
fi

# 2. Find the database network
DB_NETWORK=$(podman inspect "$DB_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | tr ' ' '\n' | grep -i 'db' | head -1)
if [[ -z "$DB_NETWORK" ]]; then
    DB_NETWORK="generated_dbnet"
fi
echo "Using database network: $DB_NETWORK"

# 3. Create AWX database
echo "Creating AWX database..."
podman exec "$DB_CONTAINER" psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='$AWX_DB_NAME'" | grep -q 1 || \
    podman exec "$DB_CONTAINER" psql -U postgres -c "CREATE DATABASE $AWX_DB_NAME OWNER gateway;"

# 4. Extract JWT public key from gateway
echo "Extracting JWT public key from gateway..."
JWT_KEY=$(podman exec "$GW_CONTAINER" bash -c 'cat << "PYEOF" | aap-gateway-manage shell -i python
from aap_gateway_api.utils.preferences import get_preference_value
print(get_preference_value("proxy", "jwt_public_key", encrypted=False))
PYEOF' 2>/dev/null | grep -A100 'BEGIN PUBLIC KEY' | head -20)

if [[ -z "$JWT_KEY" ]]; then
    echo "Warning: Could not extract JWT key. Auth through gateway will not work."
fi

# 5. Write settings with JWT key
SETTINGS_FILE=$(mktemp)
cat "$SCRIPT_DIR/awx_settings.py" > "$SETTINGS_FILE"
if [[ -n "$JWT_KEY" ]]; then
    cat >> "$SETTINGS_FILE" << JWTEOF

ANSIBLE_BASE_JWT_KEY = """${JWT_KEY}"""
JWTEOF
fi

# 6. Remove existing container if present
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# 7. Start AWX container
echo "Starting AWX container..."
podman run -d \
    --name "$CONTAINER_NAME" \
    --user root \
    --network "$DB_NETWORK" \
    -v "$SETTINGS_FILE:/etc/tower/conf.d/settings.py:z" \
    -v "$SCRIPT_DIR/uwsgi.ini:/etc/tower/uwsgi.ini:z" \
    -v "$SCRIPT_DIR/supervisord.conf:/etc/supervisord_web.conf:z" \
    -p "${AWX_PORT}:${AWX_PORT}" \
    "$AWX_IMAGE" \
    /usr/bin/launch_awx_web.sh

# 8. Run migrations
echo "Running AWX migrations (this may take a minute)..."
podman exec "$CONTAINER_NAME" awx-manage migrate --noinput 2>&1 | tail -3

# 9. Create admin user
echo "Creating admin superuser..."
podman exec "$CONTAINER_NAME" bash -c \
    "DJANGO_SUPERUSER_PASSWORD='$GATEWAY_PASSWORD' awx-manage createsuperuser --username '$GATEWAY_USERNAME' --email admin@localhost --noinput" 2>/dev/null || true

# 10. Create preload data (Default org, demo content)
echo "Creating preload data..."
podman exec "$CONTAINER_NAME" awx-manage create_preload_data 2>&1 | tail -3

# 11. Wait for uwsgi to be ready
echo "Waiting for AWX to be ready..."
for i in $(seq 1 30); do
    if curl -sf "http://localhost:${AWX_PORT}/api/controller/v2/ping/" &>/dev/null; then
        echo "AWX is ready!"
        break
    fi
    sleep 2
done

# 11. Register all services in gateway via the gateway's own playbook
echo "Registering services in gateway..."
GW_DIR="${AAP_GATEWAY_DIR:-../aap-gateway}"
if [[ -f "$GW_DIR/Makefile" ]]; then
    make -C "$GW_DIR" register-services 2>&1 | tail -5
    echo "  Services registered via gateway playbook"
else
    echo "  Warning: Gateway Makefile not found at $GW_DIR, skipping register-services"
fi

# 12. Patch controller service to point at AWX (HTTP on AWX_PORT)
echo "Updating controller service for AWX..."
GW_CURL="curl -sk -u ${GATEWAY_USERNAME}:${GATEWAY_PASSWORD} -H Content-Type:application/json"
CTRL_SVC_ID=$($GW_CURL "${GATEWAY_URL}/api/gateway/v1/services/" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(next((s['id'] for s in d['results'] if s.get('api_slug')=='controller'), ''))" 2>/dev/null) || true

if [[ -n "$CTRL_SVC_ID" ]]; then
    $GW_CURL -X PATCH \
        -d "{\"service_port\":${AWX_PORT},\"is_service_https\":false}" \
        "${GATEWAY_URL}/api/gateway/v1/services/${CTRL_SVC_ID}/" >/dev/null 2>&1
    echo "  Controller service updated (port=${AWX_PORT}, http)"
else
    echo "  Error: Controller service not found after register-services"
fi

# 13. Set up resource sync between gateway and AWX
echo "Setting up resource sync..."

# Generate service secret on gateway
SYNC_SECRET=$(podman exec "$GW_CONTAINER" aap-gateway-manage generate_service_secret controller 2>/dev/null)
if [[ -n "$SYNC_SECRET" ]]; then
    echo "  Service secret generated"

    # Get AWX service_id
    AWX_SERVICE_ID=$(podman exec "$CONTAINER_NAME" awx-manage shell -c \
        "from ansible_base.resource_registry.models import service_id; print(service_id())" 2>/dev/null | tail -1)
    echo "  AWX service_id: $AWX_SERVICE_ID"

    # Set service_id on gateway's controller cluster
    podman exec "$GW_CONTAINER" bash -c "echo \"
from aap_gateway_api.models.service_cluster import ServiceCluster
sc = ServiceCluster.objects.get(name='controller')
sc.service_id = '$AWX_SERVICE_ID'
sc.save()
\" | aap-gateway-manage shell" >/dev/null 2>&1
    echo "  Controller cluster service_id set"

    # Append RESOURCE_SERVER config to AWX settings
    podman exec "$CONTAINER_NAME" bash -c "cat >> /etc/tower/conf.d/settings.py << RSEOF

RESOURCE_SERVER = {
    \"URL\": \"https://gateway1:8000\",
    \"SECRET_KEY\": \"${SYNC_SECRET}\",
    \"VALIDATE_HTTPS\": False,
}
RSEOF"
    echo "  RESOURCE_SERVER config written"

    # Restart uwsgi to pick up new settings
    podman exec "$CONTAINER_NAME" bash -c "kill -HUP \$(pgrep -f 'uwsgi.*master' | head -1)" 2>/dev/null || true
    for i in $(seq 1 15); do
        curl -sf "http://localhost:${AWX_PORT}/api/controller/v2/ping/" &>/dev/null && break
        sleep 2
    done
    echo "  AWX restarted with RESOURCE_SERVER config"

    # Run migrate_service_data on gateway (controller only succeeds, others expected to fail)
    podman exec "$GW_CONTAINER" aap-gateway-manage migrate_service_data \
        --username "$GATEWAY_USERNAME" -v1 2>&1 | tail -5 || true

    # Force has_ran flag (galaxy/eda not running = expected failures)
    podman exec "$GW_CONTAINER" bash -c "echo \"
from aap_gateway_api.models import MigrateServiceDataHasRan
obj = MigrateServiceDataHasRan.objects.first()
if obj:
    obj.has_ran = True
    obj.save()
\" | aap-gateway-manage shell" >/dev/null 2>&1
    echo "  migrate_service_data completed"

    # Sync resources from gateway to AWX
    podman exec "$CONTAINER_NAME" awx-manage resource_sync 2>&1 | tail -5 || true
    echo "  Resource sync completed"
else
    echo "  Warning: Could not generate service secret. Resource sync skipped."
fi

echo ""
echo "=== Controller environment ready ==="
echo "Direct:  http://localhost:${AWX_PORT}/api/controller/v2/"
echo "Gateway: ${GATEWAY_URL}/api/controller/v2/"
echo ""
echo "Note: Gateway routing via envoy takes ~60s to refresh."
echo "      Wait before testing through the gateway URL."
echo ""
echo "Teardown: $0 teardown"
