# etcetera

<img src="Design/icon/poppins-icon-shaded.svg" width="128" alt="The etcetera icon">

etcetera, a native macOS browser and editor for etcd.

## Installing

Download the disk image from the
[latest release](https://github.com/Schwaggot/etcetera/releases/latest), open
it, and drag Etcetera to Applications. It needs macOS 26 on Apple silicon.
The app is not notarized, so macOS blocks it the first time: try to open it
once, then choose Open Anyway in System Settings > Privacy & Security. To
update, install a newer release the same way over the old one.

## Requirements: etcd's JSON gateway

etcetera talks to etcd through the JSON gateway that etcd serves on its client
port, not through native gRPC. This keeps the app free of a gRPC and protobuf
runtime. The gateway is on by default, and etcetera finds the right path
prefix (`/v3alpha`, `/v3beta`, or `/v3`) for etcd 3.2 and later on its own.

A cluster started with `--enable-grpc-gateway=false` cannot be used. etcetera
says so when it connects rather than failing with a vague error. To check a
cluster (etcd 3.4 and later; older releases use `/v3beta` or `/v3alpha`):

```
curl -X POST http://127.0.0.1:2379/v3/maintenance/status -d '{}'
```

A JSON reply means the gateway is available; a 404 means it is off.

What the gateway costs:

- No watch progress notifications. Watches still resume from the last seen
  revision after a reconnect, so no events are lost.
- Larger payloads. Every key and value travels base64 encoded inside JSON,
  so large ranges are slower than with etcdctl.

## Releasing

1. Move the entries under `## [Unreleased]` in `CHANGELOG.md` to a new
   `## [x.y.z] - date` heading, then run `Tools/version.sh --apply` to copy
   the version into the Xcode project and the CLI.
2. Commit, tag the commit `x.y.z` (without a `v`), and push the tag.

The Release workflow then runs the tests, builds an arm64 disk image, and
publishes it as a GitHub Release with the version's changelog section as its
notes.
