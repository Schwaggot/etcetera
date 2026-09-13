#!/bin/sh
# Regenerates the EtcdSchema test fixtures with the pinned protoc. See SPEC 6.5.
# Outputs are deterministic and committed; never edit them by hand.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Tools/protoc/fetch-protoc.sh"
PROTOC="$ROOT/Tools/protoc/bin/protoc"
FIX="$ROOT/Tests/EtcdSchemaTests/Fixtures"
cd "$FIX"

# Every .proto under a root, relative and byte-sorted.
protos_under() {
    (cd "$1" && find . -name '*.proto' | sed 's|^\./||' | LC_ALL=C sort)
}

compile() {
    root="$1"
    out="$2"
    # shellcheck disable=SC2046
    "$PROTOC" --descriptor_set_out="$out" --include_imports --include_source_info \
        -I "$root" $(protos_under "$root")
}

compile protos schema.pb

# A 500-message schema for the descriptor loading budget.
mkdir -p large/perf/v1
{
    echo 'syntax = "proto3";'
    echo 'package perf.v1;'
    i=0
    while [ "$i" -lt 500 ]; do
        echo "enum Kind$i { KIND${i}_UNSPECIFIED = 0; KIND${i}_A = 1; }"
        echo "message M$i {"
        echo "  string name = 1; int64 id = 2; double score = 3; bool on = 4;"
        echo "  repeated string tags = 5; map<string, int32> counts = 6; Kind$i kind = 7;"
        if [ "$i" -gt 0 ]; then
            echo "  M$((i - 1)) previous = 8; repeated M$((i - 1)) history = 9;"
        fi
        echo "  message Inner { string note = 1; }"
        echo "  Inner inner = 10;"
        echo "}"
        i=$((i + 1))
    done
} > large/perf/v1/large.proto
compile large large.pb

# Each message fixture names its type on a "# proto-message:" line and may
# pick another schema root with "# schema:".
for input in messages/*.txtpb; do
    base="${input%.txtpb}"
    type="$(sed -n 's/^# proto-message: //p' "$input")"
    root="$(sed -n 's/^# schema: //p' "$input")"
    [ -n "$root" ] || root=protos
    # shellcheck disable=SC2046
    "$PROTOC" --encode="$type" -I "$root" $(protos_under "$root") < "$input" > "$base.bin"
    # shellcheck disable=SC2046
    "$PROTOC" --decode="$type" -I "$root" $(protos_under "$root") < "$base.bin" > "$base.decoded.txt"
done
