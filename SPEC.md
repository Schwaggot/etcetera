# etcetera

A native macOS browser and editor for etcd.

## 1. Overview

etcetera is a desktop application for reading and editing the contents of an
etcd v3 cluster. It aims to be to etcd what Bruno and Insomnia are to HTTP
APIs: a fast, native tool that makes an opaque system legible.

The project has three parts.

1. **EtcdKit**, a standalone etcd v3 client library. It speaks the etcd JSON
   gateway over HTTP and HTTPS. It has no dependency on the application and can
   be used on its own.
2. **The application**, a SwiftUI shell around EtcdKit. It provides a key
   browser, a value editor, and connection management.
3. **Schema mapping**, an optional layer that decodes values stored as protobuf
   into readable JSON, using `.proto` files the user supplies at runtime.

### 1.1 Goals

- Make an etcd keyspace as easy to navigate as a filesystem.
- Read and write values safely, without clobbering concurrent writes.
- Show protobuf-encoded values as JSON, without shipping any schema in the app.
- Run as a native, sandboxed macOS application.
- Keep the client library usable outside the application.

### 1.2 Non-goals

- No cluster administration. Member add and remove, defragmentation, and
  snapshot restore are out of scope for version 1.0.
- No gRPC, ever. JSON over HTTP is the transport. See section 3.1.
- No cross-platform UI. The application is macOS only.
- No etcd v2 support in any form. The v2 API is removed in etcd 3.6 and will
  not be implemented, detected, or mentioned in the interface.

### 1.3 Platform

- Minimum deployment target: macOS 26.
- Built with Swift 6.4 and Xcode 27.
- Strict concurrency enabled. All public API is `Sendable`.

---

## 2. Repository layout

```
etcetera/
  Package.swift              EtcdKit and the CLI
  Sources/
    EtcdKit/                 the client library, no UI imports
    EtcdSchema/              protobuf descriptor and wire handling
    etcetera-cli/            command line front end
  Tests/
    EtcdKitTests/
    EtcdSchemaTests/
  App/
    Etcetera.xcodeproj       the macOS application
    Etcetera/                SwiftUI and AppKit code
  Tools/
    protoc/                  vendored protoc binary, see 5.2
  SPEC.md
  README.md
  LICENSE                    MIT
```

The application depends on the package. The package never depends on the
application. `EtcdKit` imports only Foundation and the toolchain's
Synchronization module. It must compile and its tests
must pass without any part of `App/` present.

---

## 3. Part one: EtcdKit

### 3.1 Why not gRPC

etcd's native API is gRPC over HTTP/2 with protobuf payloads. etcd also exposes
the same API as JSON over HTTP through its built-in gRPC gateway. EtcdKit uses
the gateway.

The reasons are dependency weight and build complexity. A gRPC path requires a
gRPC runtime, a protobuf runtime, a code generator, and a build step that
compiles etcd's `.proto` files. The gateway path requires `URLSession` and
`Codable`, both of which ship with the system.

The cost is real and must be documented for users. The gateway can be turned
off by an operator with `--enable-grpc-gateway=false`, in which case etcetera
cannot connect. Watch progress notifications and response fragmentation are not
exposed through the gateway. Large ranges are slower, because every key and
value is base64 encoded and wrapped in JSON.

Nothing in the design forecloses a gRPC transport later. See section 3.3.

### 3.2 Module boundary

`EtcdKit` is a library target with no knowledge of the application. It imports
Foundation, plus Synchronization for `Mutex`, and nothing else. It contains no
AppKit, no SwiftUI, no Combine, and no Keychain code.

The boundary is enforced by three rules.

1. The library never reads global state. Configuration arrives through
   `EtcdClient.Configuration`, passed at construction.
2. The library never prompts, logs to the console, or presents anything. It
   reports through return values and thrown errors.
3. The library never persists anything. Storing connection profiles and secrets
   is the application's job.

Credentials arrive as values. The application fetches them from the Keychain
and hands them over. EtcdKit does not know the Keychain exists.

### 3.3 Transport abstraction

All requests pass through a single narrow protocol.

```swift
public protocol EtcdTransport: Sendable {
    func unary(path: String, body: Data) async throws -> Data
    func stream(path: String, body: Data) -> AsyncThrowingStream<Data, Error>
    func get(path: String) async throws -> Data
    func setAuthToken(_ token: String?) async
}
```

`stream` yields one element per top-level JSON value, because etcd 3.2 does not
newline-delimit them. `get` exists for `/version`, which is not POST-shaped.
`setAuthToken` attaches the token to later requests; a default implementation
ignores it.

`HTTPTransport` is the only implementation. It wraps `URLSession`. The protocol
exists to make the client testable, not to leave room for gRPC; tests use a
`MockTransport` that replays recorded fixtures. If gRPC is ever revisited, it
will be a separate decision with its own spec.

### 3.4 API version detection

etcd has moved its gateway path prefix twice.

| etcd version | Path prefix |
| --- | --- |
| 3.0 to 3.2 | `/v3alpha` |
| 3.3 | `/v3beta` |
| 3.4 and later | `/v3` |

Each release kept the previous prefix as a deprecated alias for one cycle, so
there is overlap, but no single prefix works everywhere.

Detection runs once per connection, on connect, in two stages.

**Stage one.** `GET /version` on the client port. This endpoint predates the
gateway, needs no authentication, and returns a small JSON object with
`etcdserver` and `etcdcluster` fields. Parse the `etcdserver` semantic version
and pick the prefix from the table above.

**Stage two.** If stage one fails, or returns something unparseable, probe the
prefixes in order `/v3`, `/v3beta`, `/v3alpha`. Send a minimal
`maintenance/status` request to each and take the first that does not return
404. Three requests at worst, and only on first connect.

The resolved prefix and server version are cached on the client for its
lifetime. The user may override detection in connection settings by pinning a
prefix, which is useful behind proxies that rewrite paths.

The detected version also drives feature gating. `Maintenance.Status` returns
`dbSizeInUse` only on 3.4 and later, and `Lease.Leases` does not exist before
3.3. The client exposes a `ServerCapabilities` value so the application can
hide controls the server cannot honor.

### 3.5 JSON encoding rules

The gateway follows the standard proto3 JSON mapping. Two consequences drive
most of the library's code and cause most of the bugs if ignored.

**All `bytes` fields are base64.** Keys, values, and `range_end` are encoded
with standard padded base64. EtcdKit converts at the edge. No caller ever sees
base64.

**All 64-bit integers are JSON strings.** This covers `revision`,
`mod_revision`, `create_revision`, `version`, `lease`, `count`, and
`raft_term`. Decoding these as `Int64` fails. EtcdKit uses a property wrapper
for the conversion.

**Absent fields mean default values.** The gateway omits proto3 default values
rather than emitting zeros or empty strings. Every decoded field is optional
with a documented default.

**Enums are strings.** `sort_order` takes `"ASCEND"`, not `0`.

**Some field names are not lowerCamelCase.** `LeaseGrantRequest` declares `TTL`
and `ID` in the proto, so the JSON keys are `TTL` and `ID`. Do not assume the
mapping; check the proto for each message.

Request and response types mirror the messages in etcd's `rpc.proto`. That file
is the authoritative schema. EtcdKit hand-writes the `Codable` structs rather
than generating them, which is tractable because the surface is small and
stable.

### 3.6 API surface

```swift
public actor EtcdClient {
    public init(configuration: Configuration) async throws

    // Key and value
    public func range(_ request: RangeRequest) async throws -> RangeResponse
    public func put(_ request: PutRequest) async throws -> PutResponse
    public func delete(_ request: DeleteRangeRequest) async throws -> DeleteRangeResponse
    public func txn(_ request: TxnRequest) async throws -> TxnResponse
    public func compact(revision: Int64, physical: Bool) async throws

    // Watch
    public func watch(_ request: WatchCreateRequest) -> AsyncThrowingStream<WatchEvent, Error>

    // Lease
    public func leaseGrant(ttl: Int64, id: Int64) async throws -> LeaseGrantResponse
    public func leaseRevoke(id: Int64) async throws
    public func leaseTimeToLive(id: Int64, keys: Bool) async throws -> LeaseTimeToLiveResponse
    public func leases() async throws -> [Int64]

    // Cluster and maintenance
    public func status() async throws -> StatusResponse
    public func members() async throws -> [Member]

    // Auth
    public func authenticate(name: String, password: String) async throws
}
```

Convenience methods sit on top of the primitives.

```swift
public extension EtcdClient {
    func get(_ key: String) async throws -> KeyValue?
    func list(prefix: String, keysOnly: Bool, limit: Int64?) async throws -> [KeyValue]
    func listChildren(of prefix: String, separator: Character, limit: Int64) async throws -> (nodes: [TreeNode], more: Bool)
    func put(_ key: String, value: Data, ifModRevision: Int64?) async throws -> PutResponse
}
```

`listChildren` reads one page of children and returns `more`. The application
pages on its own until `more` is false. See section 4.2.

Keys are `Data` internally, because etcd keys are arbitrary bytes and need not
be valid UTF-8. The convenience layer accepts and returns `String` and throws on
keys that cannot round trip. The application shows non-UTF-8 keys as hex.

### 3.7 Range and prefix handling

A prefix scan is a range whose end is the prefix with its last byte
incremented.

```swift
func prefixEnd(_ key: [UInt8]) -> [UInt8] {
    for i in stride(from: key.count - 1, through: 0, by: -1) where key[i] < 0xFF {
        var end = Array(key[0...i])
        end[i] += 1
        return end
    }
    return [0]   // scan the whole keyspace
}
```

A key and range end of `[0]` means every key in the store. The empty prefix
must map to this, not to an empty range.

Paging uses `limit` with `sortTarget: .key` and `sortOrder: .ascend`. The next
page starts at the last returned key with a `0x00` byte appended, the smallest
key strictly greater than it. The response `more` field tells the caller whether another page exists.

### 3.8 Watch

The gateway keeps the connection open and emits one JSON object per event
batch, each wrapped in a `result` envelope. Later versions newline-delimit
them; etcd 3.2 does not, so the stream is split on top-level JSON values
rather than lines.

```swift
var request = URLRequest(url: base.appending(path: "\(prefix)/watch"))
request.httpMethod = "POST"
request.httpBody = try encoder.encode(["create_request": createRequest])
request.timeoutInterval = 3600

let (bytes, _) = try await session.bytes(for: request)
var framer = JSONObjectFramer()
for try await byte in bytes {
    // decode and yield each complete value the framer returns
}
```

Requirements.

- One HTTP connection per watch. Cancelling the consuming `Task` closes it.
- `timeoutIntervalForRequest` must be raised on the session configuration. The
  60 second default kills an idle watch.
- Reconnect with backoff when the connection drops, the server closes the
  stream, or the server is briefly unavailable (HTTP 5xx other than 501, or
  gRPC `unavailable` or `deadlineExceeded`). Backoff starts at 200 ms, doubles
  to a 5 second cap, and resets once a message arrives. The watch resumes from
  the last delivered event's revision plus one, so no events are lost. Any
  other error ends the stream; a 404 ends it with `gatewayUnavailable`.
- A rejected auth token gets one re-authentication and an immediate retry,
  as for unary calls (section 3.9). A second rejection before any message
  arrives ends the stream.
- Surface `compactRevision` in the stream. When the server has compacted past
  the resume point, the stream ends with a typed error and the caller must do a
  fresh range read. A server-side cancel also ends the stream with an error.

Stream teardown goes through the stream's `onTermination`, which cancels the
watch task, rather than duplicating cleanup at every exit.

The application runs one watch on the whole keyspace. After a compaction error
it starts a fresh watch and reloads the tree. Any other error stops live
updates and says so in the sidebar until the next connect.

### 3.9 Authentication

`POST {prefix}/auth/authenticate` with a name and password returns a token. The
token goes on every later request in the `Authorization` header as a bare
value, with no `Bearer` prefix. It is also sent as `Grpc-Metadata-Token`,
because etcd 3.2's gateway ignores `Authorization`.

Tokens expire. A 401 triggers one transparent re-authentication and one retry.
A second failure propagates. The client holds the credentials for the lifetime
of the connection; it never writes them anywhere.

### 3.10 TLS

Most production clusters use a private certificate authority, and many require
client certificates. This is the weakest part of the HTTP path and needs care.

**Custom certificate authority.** Implement
`urlSession(_:didReceive:completionHandler:)`, build a `SecTrust` over the
server chain, install the user's CA with `SecTrustSetAnchorCertificates`, and
evaluate. Never disable validation silently. An explicit "skip verification"
toggle is allowed, defaults to off, and shows a persistent warning in the
window while active.

**Client certificates.** `URLSession` needs a `SecIdentity`, which cannot be
built directly from a PEM key pair. Version 1.0 accepts a PKCS#12 file and
loads it with `SecPKCS12Import`. The connection editor shows the one-line
`openssl pkcs12 -export` command for users who hold PEM files. PEM import
without a conversion step is deferred.

### 3.11 Error model

```swift
public enum EtcdError: Error, Sendable {
    case transport(underlying: Error)
    case tls(TLSFailure)
    case gatewayUnavailable            // 404 on every probed prefix
    case unauthenticated
    case permissionDenied
    case status(code: GRPCStatusCode, message: String)
    case compacted(revision: Int64)
    case decoding(String)
    case unsupported(feature: String, requires: String)
}
```

The gateway reports gRPC failures as an HTTP status with a JSON body carrying
`error`, `code`, and `message`. Map `code` to `GRPCStatusCode` and keep the
server's message verbatim.

`gatewayUnavailable` is important enough to deserve its own case. Its user
facing message must say plainly that the cluster was started without the JSON
gateway and that etcetera cannot connect to it.

### 3.12 Command line wrapper

`etcetera-cli` is a thin executable target over `EtcdKit`. It exists to prove
the library stands alone and to make the library testable by hand.

```
etcetera-cli get /config/app --endpoints https://etcd:2379
etcetera-cli ls /config --recursive
etcetera-cli put /config/app --file value.json
etcetera-cli watch /config --prefix --rev 4021
etcetera-cli status
```

The commands are `get`, `ls`, `put`, `del`, `watch`, `status`, `members`, and
`version`. `ls` lists the direct children of a prefix, with branches ending in
`/`; `--recursive` lists every key below it instead.

Flags mirror `etcdctl` where the meaning matches, so people transfer knowledge
rather than learn a second vocabulary: `--endpoints`, `--user name[:pass]`,
`--prefix`, `--rev`, `--cacert`, `-w json`, and the `--flag=value` form. The
exception is client certificates, per section 3.10: `--cert` takes a PKCS#12
file, `--cert-pass` its passphrase, and `--key` is refused with the `openssl`
conversion command. Omitted passwords and passphrases are prompted for without
echo; the PKCS#12 passphrase only after the empty one fails. Output is plain
text by default and JSON with `--json`. Argument parsing is hand-rolled, in
keeping with section 6.1.

---

## 4. Part two: the application

### 4.1 Structure

A three-pane `NavigationSplitView`.

- **Sidebar.** The connection picker at the top, and below it the key tree for
  the connected cluster.
- **Content.** The keys under the selected tree node, in a table with columns
  for key, size, revision, and lease. Every column sorts. Keys sort by their
  bytes, as etcd orders them, and that is the default. Ties keep key order,
  and a value too large to fetch sorts as the largest size. The header's
  context menu sizes the clicked column or all columns to their content, or
  resets the widths; double-clicking a column divider fits that column.
  The same menu shows or hides Size, Revision, and Lease; Key always shows.
  Widths and hidden columns persist across launches. While a listing loads
  page by page, a translucent overlay covers the rows loaded so far with a
  running count and takes input until the last page arrives; reloads after
  writes and live updates keep the old rows usable and swap them at the end.
- **Copy.** Right-clicking a key in the tree or the table offers a Copy
  submenu: Prefix + Key, Prefix (up to and including the last separator),
  Key (the last segment), and Value, read fresh from etcd. Binary values copy
  as hex. The value editor has a copy button for the value as shown.
- **Rename and duplicate.** Keys that hold a value offer Rename Key and
  Duplicate Key in both context menus; a sheet asks for the new key.
  etcd has no rename, so one transaction puts the value, lease included,
  under the new key and deletes the old one, comparing the old key's mod
  revision. A duplicate is the same put without the delete. The new key must
  not exist (create revision == 0); when it does, the user is asked whether
  to overwrite, and the overwrite compares the revision they agreed to
  replace. A change to either key meanwhile retries up to three times. Keys
  below the key are neither moved nor copied. A renamed key's clean tab
  closes and the new key opens.
- **Export.** Both context menus offer Export As JSON, Text, or Raw Bytes
  for a key's value, saved as one file. Tree folders also export everything
  below them as a folder of files, one directory per key segment, each key's
  file carrying the format's extension (`.json`, `.txt`, `.bin`) so a key and
  the keys below it never collide. Segments are percent-escaped where they
  would not make a plain visible file name ("%", "/", a leading ".", empty).
  JSON decodes mapped protobuf values, pretty-prints JSON values in their key
  order, and writes anything else as a JSON string (hex for binary). Text is
  what Copy Value gives; raw is the stored bytes. Values too large for the
  gateway are left out and counted after saving.
- **Detail.** A tab bar over the value editor, with the inspector beside both.

**One connection at a time.** The application connects to a single endpoint.
Choosing a different connection tears down the current client, closes any
watches, and rebuilds the tree. Open tabs with unsaved edits block the switch
with a confirmation sheet. Multi-cluster work is deliberately deferred; the
model layer should not assume a single connection forever, but the interface
presents one.

**Tabs hold values, not connections.** Opening a key adds a tab. Tabs persist
across relaunch, restoring by key rather than by cached content, so a reopened
tab shows the current value and says so if it changed. A tab tracks its own
loaded revision, edit state, and view mode. Standard bindings apply: command-W
closes a tab, command-shift-bracket cycles, and a dirty tab shows the usual
close indicator.

State lives in `@Observable` model objects. The connection owns one
`EtcdClient` and one `ConnectionModel`; each tab owns a `ValueModel`. The models
translate between EtcdKit types and view state; views never call the client
directly.

### 4.2 Key tree

etcd has no directories. It has a flat, sorted, byte-ordered keyspace.
etcetera presents a tree by splitting keys on a separator, `/` by default and
configurable per connection.

Expanding a node issues one range request for that node's prefix with
`keysOnly: true` and a page limit. The results are split at the separator and
grouped. A group with children becomes a branch; a key that terminates becomes
a leaf. A key can be both, and the interface must show that case correctly: a
node that holds a value and has children.

A key that starts with the separator yields an empty first segment. When every
key does, that unnamed node is skipped: its children form the top of the tree
and load on connect. Otherwise it stays as a row labeled "(empty)", as do
empty segments from a doubled separator.

Requirements.

- Expanding a node fetches its children, not the whole keyspace. Keys-only
  pages of 1000 continue until `more` is false. A page whose last key lies
  inside a child's subtree continues after that subtree, so every page adds a
  child. There is no "load more" row.
- The table loads every page of keys with values the same way. The etcd 3.3
  gateway refuses responses over 4 MB, so a refused page is retried smaller.
  A value too large on its own is listed by key alone with an unknown size.
- Lazy loading with a spinner per node, never a modal progress sheet.
- A search field that finds keys and folders on the whole server as you
  type, ignoring case: every key whose path or name contains the query, and
  the shallowest folder whose path does. etcd has no substring search, so it
  lists every key, keys only, and reads the values that mappings name; while
  the watch runs, both are reused until something changes. It lists the
  first 500 matches, can show every match in the table, and offers a
  server-side prefix scan when the query looks like a key path.
- Live updates through one watch on the connection root, applied to the tree
  incrementally. Watches are on by default and can be turned off per
  connection for large or busy clusters.
- Non-UTF-8 key segments render as `\xNN` escapes and are not editable inline.

### 4.3 Value editor

The editor is an `NSTextView` wrapped in `NSViewRepresentable`. SwiftUI's
`TextEditor` cannot do syntax highlighting or the gutter, so AppKit is
unavoidable here.

Features.

- Line numbers, current line highlight, and bracket matching.
- Find and replace through the standard `NSTextFinder`.
- Soft wrap toggle.
- A read-only mode for values the user lacks permission to write.

**Syntax highlighting** is hand-written, not imported. A JSON tokenizer runs on
a background actor, produces ranges tagged by token type, and the main actor
applies attributes. Incremental highlighting on edit: retokenize only the lines
touched. The token types are string, number, keyword, key, punctuation, and
error. Colors come from a theme that follows the system appearance.

**Formatting** is also hand-written. A pretty-printer with configurable indent
that preserves key order, because etcd values are often configuration where
order carries meaning to the person reading it. A minify command is the
inverse. Both operate on the text buffer, not on a decoded model, so invalid
JSON can still be partially formatted.

Version 1.0 highlights JSON. The tokenizer protocol is general enough for YAML
and plain text later, and unknown content falls back to plain text.

### 4.4 Value viewer

Above the editor sits a format switcher. The app guesses the format on load and
the user can override it.

| Mode | When chosen |
| --- | --- |
| JSON | Value parses as JSON |
| Protobuf | A schema mapping matches the key, see section 5 |
| Text | Value is valid UTF-8 |
| Hex | Everything else |

Hex view is a read-only byte inspector with offsets and an ASCII gutter.

### 4.5 Saving

Every save is a transaction, never a bare put.

```
Txn(
  compare: [ modRevision(key) == loadedModRevision ],
  success: [ put(key, newValue) ],
  failure: [ range(key) ]
)
```

If the compare fails, someone else wrote the key since it was loaded. The
failure branch returns the current value, and etcetera shows a conflict sheet
with a diff and three choices: overwrite, discard local edits, or open both in
a merge view. It never writes blind.

Creating a key uses a compare on `createRevision == 0`, which fails if the key
already exists.

Deletes ask for confirmation and show the number of keys affected when a prefix
is involved.

### 4.6 Connections

A connection profile holds an endpoint, a TLS configuration, an optional
username, a key separator, a pinned API prefix, and any schema mappings.

Profiles are stored as JSON under `~/Library/Application Support/Etcetera/`.
Secrets are never stored there. Passwords, auth tokens, and the passphrase for
a PKCS#12 bundle go in the Keychain, keyed by profile identifier. Certificate
files are referenced by security-scoped bookmark, not copied.

The connection editor has a Test button that runs version detection and a
status call, and reports precisely which step failed.

A connection can be exported and imported as JSON, one at a time, like
editing. Export shows the selected connection's JSON with Copy and Save
buttons. Import takes a dropped or chosen file or the clipboard, shows what it
found, and adds the connection under a new identifier, numbering a name that is
already taken. The identifier, bookmarks, and secrets are not exported:
bookmarks resolve only on the Mac that made them, so the export names the
referenced files and the import says which to pick again.

### 4.7 History

Because `range` accepts a revision, the app offers a revision slider on any
key. Reading an older revision is free. The inspector shows create revision,
mod revision, version, and lease, and a "compare with current" view that diffs
the two. Restoring an old revision writes it as a new value through the normal
transaction path.

---

## 5. Part three: protobuf schema mapping

### 5.1 The problem

Many teams store protobuf-encoded messages in etcd. The bytes are unreadable
without the schema. etcetera lets a user point at a folder of `.proto` files
and declare that everything under a given prefix is a particular message type.

The constraint that shapes the design: **no schema is compiled into etcetera**.
The user supplies `.proto` files at runtime, so code generation is not
available. Decoding must be dynamic, driven by descriptors read at runtime.

### 5.2 Compiling the user's schema

When the user adds or refreshes a schema source, etcetera runs `protoc` once,
from inside the root:

```
protoc --descriptor_set_out=schema.pb \
       --include_imports \
       --include_source_info \
       -I . \
       -I <Contents/Resources/googleapis> \
       <every .proto under root, as ./path>
```

Running inside the root keeps a `:` in its path, or a file name starting with
`@` or `-`, from being read as protoc syntax.

The bundled `googleapis` folder holds `google/api/annotations.proto` and
`google/api/http.proto`, which schemas written for the gRPC JSON gateway,
etcd's own among them, import without shipping. It comes after the root, so a
folder's own copies win. It is passed to a custom `protoc` too.

The output is a `FileDescriptorSet`, a self-describing binary file holding
every message, field, enum, and type name in the tree. `--include_imports`
matters; without it, imported types are missing and decoding fails at the first
nested message.

`protoc` ships inside the application bundle at
`Contents/Resources/protoc`, signed as part of the app. Bundling avoids
depending on the user's Homebrew and avoids sandbox trouble around executing
arbitrary paths. For users who need a specific version, Settings offers Bundled
or Custom; Custom enables a file picker, and the chosen `protoc` is kept as a
security-scoped bookmark. A custom `protoc` that cannot be opened fails the
compile with an error rather than falling back to the bundled one.

Compilation errors are surfaced verbatim, without `protoc`'s warnings.
`protoc` messages are good and rewriting them would only lose information.

A folder often holds files that cannot compile, such as vendored APIs whose
imports are not in it. When `protoc` fails, the files its errors blame are
left out and it runs again, until it succeeds; a file importing one left out
is blamed in the next run and follows. The sidebar lists the files left out
with `protoc`'s messages, and the rest of the schema works. The compile fails
only when every file is left out, with the first run's errors, or when the
errors blame none of the files.

The compiled `schema.pb` is cached next to the profile, with the source folder's
modification times. A Refresh command recompiles. A file system watch on the
folder offers to recompile when files change.

### 5.3 Reading descriptors

`schema.pb` is itself a protobuf message, so reading it requires a protobuf
decoder. SwiftProtobuf provides one, and its runtime already ships generated
types for `descriptor.proto`. Reading the file is a single call:

```swift
let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
```

This is the one third-party dependency in the project. It is Apple maintained,
Apache 2.0, and has no transitive dependencies.

**What SwiftProtobuf does not provide.** There is no dynamic message API. The
library is built around code generated ahead of time, and its own
`SwiftProtobufPluginLibrary/Descriptor.swift` states plainly that its descriptor
wrappers exist for code generation and are not intended as a reflection or
generic message API. So SwiftProtobuf solves reading the descriptor set and
nothing beyond it.

Two consequences.

1. `EtcdSchema` builds its own `SchemaRegistry` from the raw
   `FileDescriptorProto` values: fully qualified type name to
   `MessageDescriptor`, with nested types flattened, field types linked, and
   enums resolved. Built once, immutable afterward. This is name resolution and
   graph building, not protobuf parsing, and is the smaller half of the work.
2. The wire codec in section 5.4 stays ours. SwiftProtobuf cannot decode a
   message it has no generated struct for.

Using `SwiftProtobufPluginLibrary`'s wrappers instead of building the registry
by hand is tempting and would save some code. It is not sanctioned by its
authors for this purpose, its `FileDescriptor.proto` property is already
deprecated, and a source-breaking change there would be our problem. Depend on
the `SwiftProtobuf` module only.

### 5.4 Dynamic decoding

`EtcdSchema` implements the protobuf binary wire format directly, because no
Swift library decodes a message from a runtime descriptor. The format is small
and has not changed in years.

- Wire types 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
- Wire types 3 and 4, the deprecated groups, are not produced by proto3. They
  are skipped, not parsed.
- Zigzag decoding for `sint32` and `sint64`.
- Packed encoding for repeated scalars, which is the proto3 default, with the
  unpacked form also accepted.
- Maps decoded as repeated messages with key field 1 and value field 2.
- `oneof` and explicit proto3 `optional` produce presence information.
- Unknown fields are retained, not discarded. See section 5.6.

Decoding produces a `DynamicMessage`, a tree of values keyed by descriptor.
Rendering to JSON follows the proto3 JSON mapping: lowerCamelCase names, 64-bit
integers as strings, `bytes` as base64, enums as their names.

Well-known types get their canonical JSON forms.

| Type | JSON form |
| --- | --- |
| `Timestamp` | RFC 3339 string |
| `Duration` | Seconds with an `s` suffix |
| `FieldMask` | Comma separated paths |
| `Struct`, `Value`, `ListValue` | Plain JSON |
| Wrappers | The wrapped scalar |
| `Any` | Resolved if the type is in the registry, otherwise shown as raw bytes with its type URL |

### 5.5 Mapping rules

A mapping binds a key pattern to a message type.

```json
{
  "schemaSource": "bookmark:...",
  "mappings": [
    { "prefix": "/registry/pods/",     "message": "k8s.io.api.core.v1.Pod" },
    { "prefix": "/registry/services/", "message": "k8s.io.api.core.v1.Service" },
    { "key": "/config/feature-flags",  "message": "acme.config.v1.FeatureFlags" }
  ]
}
```

Rules.

- Longest matching prefix wins. An exact `key` match beats any prefix.
- No match means the value falls back to the format guess in section 4.4.
- A match whose message name is missing from the registry is a configuration
  error, shown on the key rather than silently ignored.
- A value that fails to decode against its mapped type shows the decode error
  and offers the hex view. It never shows a half-decoded message as if it were
  complete.
- A mapped value stored as a JSON object is not decoded: many systems store
  their messages in the proto3 JSON form. It shows and edits as JSON, and Save
  writes exactly the typed text. As the user types, the text is checked
  against the message, and a mismatch, such as an unknown field or an enum
  value the schema lacks, shows as a warning naming the first problem. It
  never blocks the save, so a schema older than the data does not lock the
  value. This holds under a mapping that cannot be honored too.
- A new key under a mapped prefix is written as typed, with the same check.
- A mapping can name a field whose text labels matching keys in the UI, such
  as `name`, or `info.name` for a nested field, written `nameField` in the
  JSON. A segment also matches its lowerCamelCase form, as proto3 JSON writes
  it. A binary value is decoded with its message first. The name leads the
  key's segment in the tree, the key in the editor header and in search
  results, and fills a Name column in the table, shown only while some
  mapping has a name field. A tab shows the name in place of the last
  segment, with the full key in its tooltip. The sidebar search matches
  names too. In the tree, a level's keys with a name come first, ordered by
  name as Finder orders file names, then the rest in key order. A value
  without that field, or whose field is not a non-empty string, shows the key
  alone.
- Tree levels whose keys a mapping with a name field matches list with their
  values, cut smaller like the table's pages, falling back to keys alone
  when a value is too large; every other level stays keys-only. Names follow
  live updates and saves, and a change to the mappings fetches them again.

The mapping editor is a sheet of its own, opened from the connection editor,
which shows only how many mappings there are. It edits a copy: Done hands the
rules back and the connection editor's Save stores them, Cancel drops them.
It offers completion over every message name in the registry. Its Test
section takes a key and runs the rules being edited, before any Save: it names
the mapping the key uses by the rules above and decodes the key's live value
with that mapping's message. If that fails, it says why: no mapping matches,
the message is missing from the schema, the key does not exist, or the value
does not decode.

The mappings can be exported and imported as JSON the same way as a
connection (section 4.6), as `{"format": "etcetera-mappings", "version": 1,
"mappings": [...]}`. Import also reads the mappings from a connection export.
It either adds the imported rules, where one with the same pattern replaces
the existing rule in place, or replaces all of them. Either way it changes only
the sheet's copy, so Cancel still drops it. Export leaves out rules without a
message, since those would not import again.

### 5.6 Editing protobuf values

This section covers values stored in the wire format; values stored as JSON
save as typed (section 5.5). The user edits the JSON rendering. On save,
etcetera encodes the JSON back to
the wire format using the same descriptor, and writes the resulting bytes. A
structured editor driven by the descriptor, with typed fields and validation, is
planned for a later version; the dynamic value tree is designed to support it,
so nothing here forecloses it.

Round tripping binary data through a text form is where corruption happens, so
three safeguards apply.

1. **Unknown fields are preserved.** Fields present in the bytes but absent from
   the descriptor are kept aside during decode and re-appended on encode. A
   schema that lags the writer does not destroy data. They are carried at the
   root, into nested messages, into map values by key, and into `Any` payloads
   whose type URL is unchanged. Elements of a repeated message field are
   paired by identical known content, then by position when as many remain on
   each side. When an edit both changes elements and adds or removes others,
   so an original element carrying unknown fields cannot be paired, the save
   is refused with an explanation rather than guessed.
2. **A no-op check gates every write.** Before applying the user's edits,
   etcetera re-encodes the *unmodified* decoded value, through the same JSON
   path an edit takes, and compares it with the original bytes. A mismatch means the round trip is not faithful for this
   message, and the editor drops to read-only with an explanation. Byte-for-byte
   protobuf serialization is not guaranteed by the format, so this check is
   detection, not a promise.
3. **Field order follows the descriptor**, ascending by field number, which is
   what every mainstream implementation emits.

A save is also refused when the encoded result cannot be decoded and rendered
back, for example because it nests past the decode depth limit, so nothing is
written that cannot be opened again.

The inspector shows the original and re-encoded byte lengths side by side, so a
surprise is visible before the write.

---

## 6. Cross-cutting concerns

### 6.1 Dependency policy

`EtcdKit` has zero third-party dependencies. Foundation, plus the toolchain's
Synchronization module, only. This is a hard rule, because the library is meant to be embeddable without conditions.

`EtcdSchema` depends on exactly one package, `SwiftProtobuf`, and uses it for
one thing: decoding the `FileDescriptorSet` that `protoc` emits. It also invokes
`protoc` as a subprocess. Everything else, including the wire codec and the JSON
projection, is written here.

The application has zero third-party Swift packages. Everything it needs,
including the text editor and the JSON tokenizer, is written here or comes from
AppKit.

Adding a dependency requires a written justification in the pull request that
answers three questions: what breaks without it, how much code it replaces, and
what happens if it is abandoned. There is no in-app updater, so Sparkle is not
needed; see decision 8 in section 8.

`protoc` is a vendored binary tool, not a linked library. It is versioned in
`Tools/protoc/`, its version is recorded, and `fetch-protoc.sh` downloads that
release. Its SHA-256 checksum is verified against `protoc.sha256` at build
time, when it is embedded in the app, and before tests run it.

The two googleapis `.proto` files are vendored source, unmodified, in
`Tools/googleapis/` with their Apache 2.0 license and the commit they come
from, and are copied into the app next to `protoc`.

### 6.2 Concurrency

Strict concurrency checking is on. `EtcdClient` is an actor. All public types
crossing the boundary are `Sendable`. Model objects are `@MainActor`.
Tokenizing, descriptor parsing, and protobuf decoding run off the main actor and
publish results back. Non-actor `Sendable` types guard their mutable state
with `Mutex` from the Synchronization module.

Protobuf decoding, JSON rendering, and encoding run on a dedicated thread with
a 64 MB stack. Recursing to the nesting limits overflows a 512 KB worker thread
in a debug build, and hostile input reaches those limits.

### 6.3 Development method

The project is written test first. Every change follows the same loop: write a
failing test that states the behavior, write the least code that passes it,
then refactor with the test green.

This is not ceremony. Both hard parts of this project reward it. The etcd JSON
encoding has a dozen rules that are easy to get subtly wrong, and the protobuf
wire codec either round trips exactly or silently corrupts a user's production
configuration. Both are pure functions over bytes, which is the best possible
case for tests.

Rules.

- No production code without a failing test that demanded it. The exception is
  code with no behavior of its own, such as a view body or a type declaration.
- A bug fix begins with a test that reproduces the bug. The test is committed in
  the same change as the fix, and the commit message names the behavior.
- Refactor only on green. If a refactor needs a test changed, that is a design
  signal worth pausing on, because it means the test was coupled to structure
  rather than behavior.
- Tests describe behavior in their names, not implementation. `rejectsAWriteWhenModRevisionChanged`, not `testTxnPath`.

### 6.4 Test framework

**Swift Testing** for everything except the two cases it does not cover. It
ships with the toolchain, so it adds no dependency, and its parameterized tests
fit this project unusually well.

```swift
import Testing
@testable import EtcdKit

@Suite("Gateway prefix detection")
struct PrefixDetectionTests {
    @Test("Server version maps to the right path prefix",
          arguments: [
            ("3.2.11", "/v3alpha"),
            ("3.3.27", "/v3beta"),
            ("3.4.33", "/v3"),
            ("3.5.21", "/v3"),
            ("3.6.0",  "/v3"),
          ])
    func prefix(for version: String, expected: String) throws {
        let detected = try PrefixResolver.prefix(forServerVersion: version)
        #expect(detected == expected)
    }
}
```

Conventions.

- `@Suite` on a struct, one suite per unit of behavior. Swift Testing creates a
  fresh instance per test, so `init` is setup and `deinit` is teardown. No
  shared mutable state between tests.
- `#expect` for assertions. `try #require` when a failure makes the rest of the
  test meaningless, such as unwrapping a decoded response.
- `#expect(throws:)` for the error paths, which matter here as much as the
  success paths.
- `confirmation` for the watch stream and anything else event driven, rather
  than sleeps or expectations of elapsed time.
- Tags for selection: `.unit`, `.integration`, `.slow`, `.fuzz`. Declared once
  in an extension on `Tag`.
- Traits rather than commented-out code. `.disabled("reason")` and
  `.enabled(if:)` keep the intent visible.
- Tests run in parallel by default. A suite that cannot, such as one touching a
  shared etcd instance, carries `.serialized` and says why.

**XCTest** remains for two things only: user interface automation with
`XCUIApplication`, and performance measurement against the budgets in section
6.8. Swift 6.4 reports XCTest failures as Testing issues and allows Testing APIs
inside XCTest, so the two coexist without a wrapper layer.

No third-party test libraries. No Quick, no Nimble, no snapshot testing package.
Golden-file comparison is fifteen lines and avoids a dependency that would
outrank the entire rest of the dependency budget.

### 6.5 What gets tested, and how

**EtcdKit, unit.** Runs against `MockTransport`. No network, no Docker, runs in
under a second, runs on every save. Coverage includes:

- Every JSON encoding rule from section 3.5, especially 64-bit integers as
  strings and absent fields meaning defaults. One parameterized test per rule.
- `prefixEnd`, including the `0xFF` carry cases and the empty prefix that must
  map to the whole keyspace.
- Paging, including a final page where `more` is false and an empty result.
- The version detection table and both detection stages.
- Error mapping from gateway status codes to `EtcdError`.
- Authentication retry: one 401 triggers exactly one re-auth and one retry, and
  a second 401 propagates.

**Fixtures.** `HTTPTransport` has a record mode that writes every request and
response to disk. Fixtures are captured once from real etcd instances, one set
per supported version, and committed. Re-recording is a script, not a manual
task, so fixtures stay honest when etcd changes.

**EtcdKit, integration.** Real etcd in Docker, across 3.2, 3.3, 3.4, 3.5, and
3.6, driven by a script in `Tools/`. Tagged `.integration` so `swift test` stays
fast locally and the full matrix runs in CI. These tests exist to catch the
fixtures drifting from reality, so they assert the same things as the unit tests
rather than new things.

**EtcdSchema.** The round trip is the contract, so it is the test:

1. Encode a fixture message with `protoc`.
2. Decode it with our codec against the descriptor.
3. Re-encode.
4. Compare bytes.

Fixtures cover every scalar type, nested messages, maps, repeated packed and
unpacked, `oneof`, proto3 `optional`, unknown fields, and each well-known type.
JSON projection is tested separately against the proto3 JSON mapping, using
`protoc --decode` output as the reference.

**Fuzzing.** The wire decoder is fed malformed and truncated input, including
hostile length prefixes. It must throw, never crash, and never hang. Hostile
length prefixes throw before allocating, and a decode retains at most about 64
bytes per input byte, plus a small fixed allowance. Where a guarantee is enforced by a
precondition, an exit test (`#expect(processExitsWith:)`) proves the precondition
fires rather than the code continuing on bad state.

**Application.** Logic is tested; views are not. The tree builder takes a flat
list of keys and produces nodes, so it is a pure function and gets thorough
coverage, including the case where a key is both a value and a branch prefix.
The save path is tested at the model layer: a stale `modRevision` must produce
the conflict state and must never issue a bare put. A small XCUITest suite
covers connect, browse, edit, save.

### 6.6 Testability requirements on the design

Test-first only works if the code allows it, so three constraints are binding
rather than advisory.

1. **No singletons and no global state.** Everything a type needs arrives
   through its initializer. This is already true of `EtcdClient.Configuration`.
2. **Time is injected.** Backoff, lease TTL handling, and token refresh take a
   `Clock`. Tests supply a controlled clock and advance it by hand. No test ever
   sleeps.
3. **No `Date()`, `UUID()`, or `Task.sleep` called directly in library code.**
   Each arrives through a provider that tests replace.

### 6.7 Coverage and gates

Coverage is a smell detector, not a target. Chasing a percentage produces tests
that assert nothing.

That said, two floors are enforced in CI, because they cover the code where a
silent failure is expensive: 90 percent line coverage on `EtcdSchema`'s codec,
and 85 percent on `EtcdKit`. The application has no floor.

CI runs unit tests and the schema round trip on every push, and the Docker
matrix plus the fuzz corpus nightly and on any pull request that touches
`EtcdKit`. A failing test blocks the merge. A flaky test is deleted or fixed
within a day; it is never retried into passing.

### 6.8 Performance budgets

| Operation | Budget |
| --- | --- |
| Expand a tree node, 1000 keys | 200 ms after the response arrives |
| Highlight a 1 MB JSON value | 150 ms, incremental after the first pass |
| Decode a 100 KB protobuf message | 50 ms |
| Load a descriptor set with 500 messages | 500 ms, once per schema change |

Values above 5 MB open in read-only hex by default, with an explicit command to
load them into the editor.

Nothing that scales with a value's size runs on the main thread: highlighting
a large value, the format guess, and the history diff are computed in the
background, and the editor shows its loading state until the text is ready.

### 6.9 Security

- App Sandbox on, with `com.apple.security.network.client`.
- Hardened runtime. Releases are ad-hoc signed and not notarized; see
  decision 8 in section 8.
- Secrets in the Keychain. Never in profile JSON, never in logs.
- Certificate files and schema folders reached through security-scoped
  bookmarks. Nothing is copied into the container without saying so.
- Logs redact key values by default. A verbose mode that includes them requires
  an explicit opt-in per session and says so in the interface.
- No telemetry, no analytics, no network traffic to anywhere except the
  configured etcd endpoint.

### 6.10 Localization

The interface is in American English, the development language, and German.
Strings live in String Catalogs (`Localizable.xcstrings`): one for the app and
one each for EtcdKit, EtcdSchema, and EtceteraCore, whose strings use
`bundle: .module`. Counts use plural variations, and sentences are never built
from translated fragments. User data, key names, log messages, protocol names,
and format names such as JSON stay untranslated. `swift test` does not compile
the catalogs, so tests always see the English text.

### 6.11 Naming and trademark

etcd is a CNCF project with a trademark policy. The application is named
etcetera. It must not be presented as official. Acceptable description:
"etcetera, a native macOS browser and editor for etcd."

---

## 7. Milestones

Each milestone ships with its tests, not after them. A milestone is not done
until its tests pass with no network and the fixtures are committed.

**M0. Skeleton.** Package and application build. `MockTransport` and the fixture
recorder exist first, because everything after this depends on them. `EtcdKit`
then connects to a local etcd over plain HTTP, runs version detection, and reads
one key. CLI can `get`.

**M1. Read path.** Range, prefix scan, paging, the tree browser, the table, and
the read-only value viewer with format detection.

**M2. Write path.** Put and delete through transactions, the conflict sheet, and
key creation.

**M3. Editor.** `NSTextView` integration, JSON highlighting, formatting, find
and replace, and the tab bar with restore on relaunch.

**M4. Connections.** Profiles, Keychain, TLS with a custom CA, client
certificates from PKCS#12, authentication.

**M5. Schema.** `protoc` bundling, descriptor reading, dynamic decode, mapping
configuration, protobuf viewing. Editing lands last, behind the safeguards in
section 5.6.

**M6. Polish.** Watch-driven live updates, revision history and diff, leases,
sandbox, first release.

Getting M0 working end to end is the milestone that removes the most risk,
because it settles the transport, the version table, and the encoding rules in
one go.

---

## 8. Decisions

Settled. Reopening any of these needs a reason written down here.

1. **JSON over HTTP is the only transport.** The etcd JSON gateway is required.
   A cluster started without it is unsupported and gets a clear error, not a
   fallback. gRPC is not a future option within this spec.
2. **`protoc` is bundled**, not required on PATH. Roughly 5 MB in the
   application, and it removes a class of sandbox and version problems. An
   override for an external `protoc` remains available in settings.
3. **SwiftProtobuf is the single third-party dependency**, used only to read the
   descriptor set. The registry, the wire codec, and the JSON projection are
   ours, because SwiftProtobuf has no dynamic message support.
4. **Protobuf editing goes through JSON.** A structured editor driven by
   descriptors is a later version, not a version 1.0 feature.
5. **One connection at a time, many value tabs.** Switching connections tears
   down the client. Multi-cluster windows are deferred, but the model layer
   should not hard-code the assumption.
6. **etcd v2 is out of scope completely.**
7. **Releases are a direct download from GitHub Releases.** Pushing a version
   tag has GitHub Actions test, build an arm64 disk image, and publish it with
   the version's CHANGELOG.md section as release notes. The tag must match
   the newest version in CHANGELOG.md. The Mac App Store is ruled out: it
   forbids executing a bundled binary that is not part of the signed app's
   own code, which decision 2 needs.
8. **Releases are ad-hoc signed, and updating means installing the new
   release.** There is no Developer ID signing and no notarization, so macOS
   blocks the app on first launch until the user allows it in System
   Settings. There is no in-app updater: a new version is downloaded from
   GitHub Releases and installed over the old one.
