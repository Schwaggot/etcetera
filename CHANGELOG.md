# Changelog

All notable changes to etcetera are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The newest `## [x.y.z]` heading below is the release version, set nowhere
else by hand. `Tools/version.sh --apply` copies it into the Xcode project
(`MARKETING_VERSION`) and the CLI (`cliVersion`), and `swift test` fails when
they differ. Tag the release with the same version, without a `v`; the tag is
also the Swift package's version. The build number, `CURRENT_PROJECT_VERSION`,
only ever goes up.

## [Unreleased]

## [1.0.0] - 2026-09-13

First release. Requires macOS 26 and etcd 3.2 or later with its JSON gateway,
which is on by default.

### Added

- **Key tree.** Keys split into a tree on a separator, `/` by default and set
  per connection. Levels load lazily, page by page. Keys starting with the
  separator and doubled separators are handled, and non-UTF-8 segments show as
  `\xNN` escapes. A search field finds keys and folders anywhere on the
  server by path or readable name as you type, and offers a server-side
  prefix scan for key paths.
- **Live updates.** One watch on the whole keyspace keeps the tree and table
  current and resumes after reconnects without losing events. It can be turned
  off per connection.
- **Key table.** The keys under the selected tree node, with sortable Key,
  Name, Size, Revision, and Lease columns. Column widths and visibility persist
  across launches.
- **Value tabs.** Opened keys stay as tabs across relaunch and say when a value
  changed since the last session.
- **Value editor.** JSON syntax highlighting, line numbers, bracket matching,
  find and replace, soft wrap, and Format and Minify that keep key order.
  Values show as JSON, Protobuf, Text, or Hex, guessed on load and switchable.
- **Safe writes.** Every save compares the loaded revision. A concurrent
  change opens a conflict sheet with a diff and the choice to overwrite,
  discard, or merge. Creating a key never overwrites one, and deletes confirm
  how many keys they affect.
- **Key actions.** Copy the key, its prefix, its last segment, or its value;
  rename and duplicate keys with their lease; export a value, or a whole
  folder of keys, as JSON, text, or raw bytes.
- **History and leases.** A revision slider on any key, a diff against the
  current value, and restoring an older revision. A Leases view lists the
  cluster's leases.
- **Connections.** Saved profiles with username and password authentication,
  TLS with a custom certificate authority, PKCS#12 client certificates, and an
  opt-in to skip server verification. Secrets are kept in the Keychain. The
  API prefix is detected for etcd 3.2 to 3.6, a cluster without the gateway is
  reported plainly, and a Test button names the step that failed. Connections
  export and import as JSON.
- **Protobuf schema mapping.** A folder of `.proto` files is compiled with the
  bundled protoc, and mapping rules bind key prefixes or exact keys to message
  types, so binary values show and edit as JSON. Unknown fields are preserved,
  and a value whose round trip is not exact turns read-only. Messages stored as
  JSON are saved as typed and checked against their message. The mapping
  editor offers completion, a Test section for a live key, and JSON import and
  export.
- **Readable names.** A mapping can name a field, such as `name`, whose text
  labels its keys in the tree, table, tabs, editor, and search. Named keys sort
  first in the tree, by name.
- **Localization.** English (US) and German.
- **EtcdKit.** The etcd v3 client library the app is built on, usable on its
  own.
- **etcetera-cli.** A command line front end to EtcdKit with `get`, `ls`,
  `put`, `del`, `watch`, `status`, `members`, and `version`, taking
  etcdctl-style flags.
