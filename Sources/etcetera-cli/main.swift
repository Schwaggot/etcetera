import EtcdKit
import Foundation

// etcetera-cli: a thin front end over EtcdKit. It exists to prove the
// library stands alone and to make it testable by hand. Flags mirror
// etcdctl where the meaning matches.

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    var endpoint = URL(string: "http://127.0.0.1:2379")!
    var user: String?
    var password: String?
    var json = false
    var caCert: String?
    var cert: String?
    var certPass: String?
    var insecureSkipVerify = false
    var prefix: String?
    var positional: [String] = []
    var recursive = false
    var keysOnly = false
    var file: String?
    var revision: Int64 = 0
    var limit: Int64 = 0
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var inlineValue: String?

    // Accepts both "--flag value" and etcdctl's "--flag=value".
    func value(for flag: String) throws -> String {
        if let inlineValue { return inlineValue }
        index += 1
        guard index < arguments.count else {
            throw CLIError(description: "\(flag) needs a value")
        }
        return arguments[index]
    }

    func integer(for flag: String) throws -> Int64 {
        guard let number = Int64(try value(for: flag)) else {
            throw CLIError(description: "\(flag) needs an integer")
        }
        return number
    }

    // A bare boolean flag means true; "--flag=false" turns it off.
    func boolean(for flag: String) throws -> Bool {
        switch inlineValue {
        case nil, "true", "1": return true
        case "false", "0": return false
        default: throw CLIError(description: "\(flag) takes true or false")
        }
    }

    while index < arguments.count {
        var argument = arguments[index]
        inlineValue = nil
        if argument == "--" {
            options.positional += arguments[(index + 1)...]
            break
        }
        if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
            inlineValue = String(argument[argument.index(after: equals)...])
            argument = String(argument[..<equals])
        }
        switch argument {
        case "--endpoint", "--endpoints":
            // etcdctl takes a comma-separated list; EtcdClient talks to one endpoint.
            var raw = try value(for: argument).split(separator: ",").first.map(String.init) ?? ""
            if !raw.contains("://") { raw = "http://" + raw }
            guard let url = URL(string: raw), url.host() != nil else {
                throw CLIError(description: "invalid endpoint URL")
            }
            options.endpoint = url
        case "--user":
            // etcdctl style: name:password or just name.
            let raw = try value(for: argument)
            if let colon = raw.firstIndex(of: ":") {
                options.user = String(raw[..<colon])
                options.password = String(raw[raw.index(after: colon)...])
            } else {
                options.user = raw
            }
        case "--password":
            options.password = try value(for: argument)
        case "--json":
            options.json = try boolean(for: argument)
        case "-w", "--write-out":
            switch try value(for: argument) {
            case "json": options.json = true
            case "simple": options.json = false
            default: throw CLIError(description: "\(argument) supports simple and json")
            }
        case "--cacert":
            options.caCert = try value(for: argument)
        case "--cert":
            options.cert = try value(for: argument)
        case "--cert-pass":
            options.certPass = try value(for: argument)
        case "--key":
            throw CLIError(
                description: """
                    client certificates are read as PKCS#12 via --cert; convert a PEM pair with
                      openssl pkcs12 -export -in cert.pem -inkey key.pem -out client.p12
                    """)
        case "--insecure-skip-tls-verify":
            options.insecureSkipVerify = try boolean(for: argument)
        case "--api-prefix":
            options.prefix = try value(for: argument)
        case "--recursive", "--prefix":
            options.recursive = try boolean(for: argument)
        case "--keys-only":
            options.keysOnly = try boolean(for: argument)
        case "--file":
            options.file = try value(for: argument)
        case "--rev", "--revision":
            options.revision = try integer(for: argument)
        case "--limit":
            options.limit = try integer(for: argument)
        default:
            if argument.hasPrefix("--") {
                throw CLIError(description: "unknown flag \(argument)")
            }
            options.positional.append(argument)
        }
        index += 1
    }
    return options
}

/// Reads without echo from the terminal, or from stdin when there is none.
func readSecret(prompt: String) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let secret = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) else { return "" }
    return String(cString: secret)
}

func readFile(_ path: String) throws -> Data {
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw CLIError(description: "cannot read \(path): \(error.localizedDescription)")
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func makeClient(_ options: Options) async throws -> EtcdClient {
    var tls = TLSConfiguration(skipServerVerification: options.insecureSkipVerify)
    if options.insecureSkipVerify {
        warn("warning: the server certificate is not verified (--insecure-skip-tls-verify)")
    }
    if let caCert = options.caCert {
        tls.customRootCertificates = [try readFile(caCert)]
    }
    let identity = try options.cert.map(readFile)

    func connect(passphrase: String) async throws -> EtcdClient {
        tls.clientIdentity = identity.map { ($0, passphrase) }
        return try await EtcdClient(
            configuration: .init(endpoint: options.endpoint, tls: tls, pinnedPrefix: options.prefix))
    }

    let client: EtcdClient
    do {
        client = try await connect(passphrase: options.certPass ?? "")
    } catch EtcdError.tls(.invalidPKCS12) where identity != nil && options.certPass == nil {
        // Many PKCS#12 files have no passphrase, so ask only once the empty one fails.
        client = try await connect(passphrase: readSecret(prompt: "PKCS#12 passphrase: "))
    }

    if let user = options.user {
        let password = options.password ?? readSecret(prompt: "Password: ")
        try await client.authenticate(name: user, password: password)
    }
    return client
}

func printJSON(_ value: some Encodable, compact: Bool = false) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "")
}

func printable(_ bytes: Data) -> String {
    String(data: bytes, encoding: .utf8) ?? bytes.map { String(format: "\\x%02x", $0) }.joined()
}

func printKeyValue(_ kv: KeyValue, keysOnly: Bool) {
    print(printable(kv.key))
    if !keysOnly {
        print(printable(kv.value))
    }
}

struct ChildrenOutput: Encodable {
    struct Node: Encodable {
        var name: String
        var path: String
        var isLeaf: Bool
        var hasChildren: Bool
    }

    var nodes: [Node]
    /// More keys exist than were scanned, so the list may be incomplete.
    var more: Bool
}

struct WatchEventOutput: Encodable {
    var type: String
    var kv: KeyValue
    var prevKv: KeyValue?
    @StringInt64 var revision: Int64

    enum CodingKeys: String, CodingKey {
        case type, kv, revision
        case prevKv = "prev_kv"
    }
}

struct VersionOutput: Encodable {
    var server: String?
    var apiPrefix: String
}

/// Set from CHANGELOG.md by Tools/version.sh --apply; do not edit by hand.
let cliVersion = "1.0.0"

let usage = """
    usage: etcetera-cli <command> [arguments] [flags]
           etcetera-cli --version

    commands:
      get <key>             read one key (--rev N reads an older revision)
      ls [prefix]           list the direct children of a prefix; branches end in "/"
                            (--recursive lists every key below it, --keys-only, --limit N)
      put <key> [value]     write a key (--file path reads the value from a file)
      del <key>             delete a key (--prefix deletes every key under it)
      watch <key>           stream changes (--prefix, --rev N)
      status                server status
      members               cluster members
      version               detected server version and API prefix

    connection flags:
      --endpoints URL       default http://127.0.0.1:2379; the first of a list is used
      --user name[:pass]    authenticate; prompts for the password when it is omitted
      --password pass
      --api-prefix /v3      pin the gateway prefix and skip detection
      --cacert file         trust this CA (PEM or DER) instead of the system roots
      --cert file.p12       client certificate and key as PKCS#12; convert PEM files with
                              openssl pkcs12 -export -in cert.pem -inkey key.pem -out client.p12
      --cert-pass pass      PKCS#12 passphrase; prompted for when needed and omitted
      --insecure-skip-tls-verify
                            do not verify the server certificate

    output flags:
      --json, -w json       JSON output; watch prints one JSON object per line

    Flags also accept the --flag=value form. etcetera needs etcd's JSON gateway.
    """

func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, !["--help", "-h", "help"].contains(command) else {
        print(usage)
        return
    }
    if command == "--version" {
        print("etcetera-cli \(cliVersion)")
        return
    }
    let options = try parseOptions(Array(arguments.dropFirst()))
    // Line buffering so piped watch output arrives as it happens.
    setvbuf(stdout, nil, _IOLBF, 0)

    switch command {
    case "get":
        guard let key = options.positional.first else {
            throw CLIError(description: "get needs a key")
        }
        let client = try await makeClient(options)
        let response = try await client.range(
            RangeRequest(key: Data(key.utf8), revision: options.revision))
        guard let kv = response.kvs.first else {
            warn("key not found")
            exit(1)
        }
        if options.json {
            try printJSON(kv)
        } else {
            printKeyValue(kv, keysOnly: false)
        }

    case "ls":
        let prefix = options.positional.first ?? ""
        let client = try await makeClient(options)
        if options.recursive {
            let kvs = try await client.list(
                prefix: prefix, keysOnly: options.keysOnly || !options.json,
                limit: options.limit == 0 ? nil : options.limit)
            if options.json {
                try printJSON(kvs)
            } else {
                for kv in kvs {
                    printKeyValue(kv, keysOnly: true)
                }
            }
        } else {
            let (nodes, more) = try await client.listChildren(
                of: prefix, separator: "/", limit: options.limit == 0 ? 1000 : options.limit)
            if options.json {
                try printJSON(
                    ChildrenOutput(
                        nodes: nodes.map {
                            .init(name: $0.name, path: $0.path, isLeaf: $0.isLeaf, hasChildren: $0.hasChildren)
                        },
                        more: more))
            } else {
                // A key that is also a branch prefix prints on both lines.
                for node in nodes {
                    if node.isLeaf { print(node.path) }
                    if node.hasChildren { print(node.path + "/") }
                }
                if more {
                    warn("note: more keys exist than were scanned; raise --limit or use --recursive")
                }
            }
        }

    case "put":
        guard let key = options.positional.first else {
            throw CLIError(description: "put needs a key")
        }
        let value: Data
        if let file = options.file {
            value = try readFile(file)
        } else if options.positional.count > 1 {
            value = Data(options.positional[1].utf8)
        } else {
            throw CLIError(description: "put needs a value or --file")
        }
        let client = try await makeClient(options)
        let response = try await client.put(PutRequest(key: Data(key.utf8), value: value))
        if options.json {
            try printJSON(response)
        } else {
            print("OK (revision \(response.header.revision))")
        }

    case "del":
        guard let key = options.positional.first else {
            throw CLIError(description: "del needs a key")
        }
        let keyData = Data(key.utf8)
        let client = try await makeClient(options)
        let response = try await client.delete(
            DeleteRangeRequest(
                key: options.recursive ? prefixStart(keyData) : keyData,
                rangeEnd: options.recursive ? prefixEnd(keyData) : Data()))
        if options.json {
            try printJSON(response)
        } else {
            print(response.deleted)
        }

    case "watch":
        guard let key = options.positional.first else {
            throw CLIError(description: "watch needs a key")
        }
        let keyData = Data(key.utf8)
        let client = try await makeClient(options)
        let request = WatchCreateRequest(
            key: keyData,
            rangeEnd: options.recursive ? prefixEnd(keyData) : Data(),
            startRevision: options.revision)
        for try await event in client.watch(request) {
            let kind = event.kind == .put ? "PUT" : "DELETE"
            if options.json {
                try printJSON(
                    WatchEventOutput(
                        type: kind, kv: event.kv, prevKv: event.prevKv,
                        revision: StringInt64(wrappedValue: event.revision)),
                    compact: true)
                continue
            }
            print("\(kind) \(printable(event.kv.key)) (revision \(event.revision))")
            if event.kind == .put {
                print(printable(event.kv.value))
            }
        }

    case "status":
        let client = try await makeClient(options)
        let status = try await client.status()
        if options.json {
            try printJSON(status)
        } else {
            print("version:  \(status.version)")
            print("dbSize:   \(status.dbSize)")
            if let inUse = status.dbSizeInUse {
                print("dbInUse:  \(inUse)")
            }
            print("leader:   \(status.leader)")
            print("raftTerm: \(status.raftTerm)")
        }

    case "members":
        let client = try await makeClient(options)
        let members = try await client.members()
        if options.json {
            try printJSON(members)
        } else {
            for member in members {
                print("\(member.name.isEmpty ? String(member.id) : member.name)  \(member.clientURLs.joined(separator: ","))")
            }
        }

    case "version":
        let client = try await makeClient(options)
        let server = client.serverVersion.map(String.init(describing:))
        if options.json {
            try printJSON(VersionOutput(server: server, apiPrefix: client.apiPrefix))
        } else {
            print("server:     \(server ?? "unknown")")
            print("api prefix: \(client.apiPrefix)")
        }

    default:
        throw CLIError(description: "unknown command \(command)\n\(usage)")
    }
}

do {
    try await run()
} catch let error as CLIError {
    warn("error: \(error.description)")
    exit(2)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    warn("error: \(message)")
    exit(1)
}
