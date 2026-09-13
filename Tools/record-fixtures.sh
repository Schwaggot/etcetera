#!/bin/sh
# Records gateway fixtures from real etcd, one Docker container per supported
# version, by running the integration suite against each. The same run is the
# integration test matrix. See SPEC 6.5.
#
# Usage: Tools/record-fixtures.sh [version ...]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/Tests/EtcdKitTests/Fixtures"
VERSIONS="${*:-3.2.32 3.3.27 3.4.35 3.5.21 3.6.4}"
PORT="${ETCETERA_FIXTURE_PORT:-23790}"
PASSWORD="etcetera-fixture"
CONTAINER="etcetera-fixture"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
swift build --build-tests | grep -E "error|warning: " || true
swift build --build-tests >/dev/null

start() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker run -d --name "$CONTAINER" -p "$PORT:2379" "gcr.io/etcd-development/etcd:v$1" \
        /usr/local/bin/etcd --name fixture --data-dir /tmp/etcd \
        --listen-client-urls http://0.0.0.0:2379 \
        --advertise-client-urls "http://127.0.0.1:2379" $2 >/dev/null
    for _ in $(seq 1 120); do
        curl -fs "http://127.0.0.1:$PORT/version" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    echo "etcd $1 did not start" >&2
    docker logs "$CONTAINER" >&2
    exit 1
}

ctl() {
    docker exec -e ETCDCTL_API=3 "$CONTAINER" etcdctl --endpoints=http://127.0.0.1:2379 "$@"
}

scenario() {
    rm -f "$3"
    ETCETERA_ETCD_ENDPOINT="http://127.0.0.1:$PORT" \
        ETCETERA_ETCD_VERSION="$1" \
        ETCETERA_SCENARIO="$2" \
        ETCETERA_RECORD_TO="$3" \
        ETCETERA_ETCD_PASSWORD="$PASSWORD" \
        swift test --skip-build --filter IntegrationTests
}

for version in $VERSIONS; do
    echo "== etcd $version"
    start "$version" ""
    scenario "$version" main "$FIXTURES/etcd-$version.jsonl"
    ctl user add "root:$PASSWORD" >/dev/null
    ctl role add root >/dev/null 2>&1 || true
    ctl user grant-role root root >/dev/null 2>&1 || true
    ctl auth enable >/dev/null
    scenario "$version" auth "$FIXTURES/etcd-$version-auth.jsonl"
done

echo "== etcd 3.6.4 without the JSON gateway"
start 3.6.4 "--enable-grpc-gateway=false"
scenario 3.6.4 gateway-off "$FIXTURES/etcd-3.6.4-gateway-off.jsonl"

docker rm -f "$CONTAINER" >/dev/null
echo "Fixtures written to $FIXTURES"
