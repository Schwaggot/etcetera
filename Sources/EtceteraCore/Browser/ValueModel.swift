import EtcdKit
import EtcdSchema
import Foundation
import Observation

/// State for one displayed value: the loaded key-value pair, its guessed
/// format, the user's override, and the edit buffer with its guarded save.
/// Keys mapped to a protobuf message edit as JSON; one stored as JSON saves
/// as typed. See SPEC 4.4 to 4.5 and 5.
@MainActor
@Observable
public final class ValueModel {
    public enum State: Sendable {
        case idle
        case loading
        case loaded(KeyValue)
        case missing
        case failed(String)
    }

    public enum SaveState: Sendable {
        case idle
        case saving
        case saved
        /// Someone wrote the key since it was loaded; `current` is what the
        /// store holds now, nil when the key was deleted. See SPEC 4.5.
        case conflict(current: KeyValue?)
        case failed(String)
    }

    /// Values above this size open read-only in hex. See SPEC 6.8.
    public static let hexThreshold = 5_000_000

    public private(set) var state: State = .idle
    public private(set) var saveState: SaveState = .idle
    /// The format switcher selection; reset to the guess on every load.
    public var format: ValueFormat = .text
    /// The edit buffer: the value as text, or a protobuf value's JSON.
    public var text = "" {
        didSet { if isStoredAsJSON, text != checkedText { scheduleSchemaCheck() } }
    }
    /// How the key's schema mapping resolved at load.
    public private(set) var mapping: MappingResolution = .unmapped
    /// The decoded message, when the key is mapped and its bytes decode.
    public private(set) var protobuf: DecodedProtobufValue?
    /// Why a mapped value did not decode; its bytes stay viewable as hex.
    public private(set) var protobufError: String?
    /// A mapped value stored as a JSON object: shown and saved as typed, and
    /// only checked against the message. See SPEC 5.5.
    public private(set) var isStoredAsJSON = false
    /// How the buffer compares with the mapped message, for a value stored as JSON.
    public private(set) var schemaCheck: SchemaCheck?
    /// The re-check after an edit; tests await it.
    private(set) var schemaCheckTask: Task<Void, Never>?
    /// The text `schemaCheck` describes.
    private var checkedText: String?
    private var codec: ProtobufValueCodec?
    /// The text of the value the buffer started from, for the dirty check.
    private var baselineText = ""
    /// A value above the hex threshold the user chose to edit anyway.
    private var editorOverride = false
    /// A history version being restored; Overwrite writes these exact bytes.
    private var pendingRestore: Data?
    /// The connection session the value was loaded in.
    private var session: Int?
    private var generation = 0

    private enum Decoding: Sendable {
        case decoded(DecodedProtobufValue)
        case failed(String)
    }

    public init() {}

    public var loaded: KeyValue? {
        if case .loaded(let kv) = state { return kv }
        return nil
    }

    public var isLarge: Bool { (loaded?.value.count ?? 0) > Self.hexThreshold }
    public var isDirty: Bool { loaded != nil && text != baselineText }

    public var mappedMessage: String? {
        if case .mapped(let message, _) = mapping { return message }
        return nil
    }

    /// The message the bytes decode as; nil for a value stored as JSON.
    private var protobufMessage: String? { isStoredAsJSON ? nil : mappedMessage }

    public var schemaProblem: String? {
        if case .misconfigured(_, let reason) = mapping { return reason }
        return nil
    }

    /// Protobuf appears only when a mapping matches the key.
    public var availableFormats: [ValueFormat] {
        protobufMessage == nil ? ValueFormat.allCases.filter { $0 != .protobuf } : ValueFormat.allCases
    }

    public var isEditable: Bool {
        guard let loaded else { return false }
        // The bytes are a message nobody can encode right now.
        if case .misconfigured = mapping, !isStoredAsJSON { return false }
        if protobufMessage != nil {
            // The no-op check gates every protobuf write. See SPEC 5.6.
            return format == .protobuf && protobuf?.roundTrip.isFaithful == true
        }
        guard format == .json || format == .text else { return false }
        return (editorOverride || !isLarge) && String(data: loaded.value, encoding: .utf8) != nil
    }

    /// Why a decoded protobuf value is read-only.
    public var readOnlyReason: String? {
        guard format == .protobuf, let report = protobuf?.roundTrip, !report.isFaithful else { return nil }
        return String(
            localized: "Re-encoding this message unchanged does not reproduce the stored bytes (\(report.originalLength) stored, \(report.reencodedLength) re-encoded), so editing is off to protect the data.",
            bundle: .module)
    }

    /// The current store value against the local edits, for the conflict sheet.
    public var conflictDiff: [DiffLine] {
        guard case .conflict(let current) = saveState else { return [] }
        return LineDiff.diff(
            old: current.map { renderedText(for: $0.value) } ?? "", new: pendingRestore.map(renderedText(for:)) ?? text)
    }

    // MARK: Loading

    public func load(key: Data, from connection: ConnectionModel) async {
        generation += 1
        let current = generation
        state = .loading
        saveState = .idle
        editorOverride = false
        session = connection.session
        do {
            let kv = try await connection.value(forKey: key)
            guard current == generation else { return }
            guard let kv else {
                state = .missing
                return
            }
            await present(kv, schema: connection)
        } catch {
            guard current == generation else { return }
            state = .failed(ConnectionModel.message(for: error))
        }
    }

    /// Re-reads the mapping after the schema changed; unsaved edits win.
    public func schemaChanged(on connection: ConnectionModel) async {
        guard let loaded, !isDirty else { return }
        generation += 1
        await present(loaded, schema: connection, keepingEdits: true)
    }

    /// Changes nothing until decoding finishes, so a save never pairs the
    /// new mapping with the old buffer. `keepingEdits` yields to typing
    /// that happened meanwhile.
    private func present(_ kv: KeyValue, schema connection: ConnectionModel, keepingEdits: Bool = false) async {
        let current = generation
        connection.queueNames(of: [kv], readIn: session)
        let mapping = connection.mapping(forKey: kv.key)
        var message: String?
        if case .mapped(let name, _) = mapping { message = name }
        let codec = message == nil ? nil : connection.schemaRegistry.map { ProtobufValueCodec(registry: $0) }
        // Protobuf decoding and the format guess, which parses JSON, run off
        // the main actor. See SPEC 6.2. A message stored as JSON is shown as
        // stored and only checked. See SPEC 5.5.
        var storedAsJSON = false
        if mapping != .unmapped {
            storedAsJSON = await Task.detached { MessageCheck.isJSONObject(kv.value) }.value
        }
        let decoding = storedAsJSON ? nil : await Self.decodeDetached(kv.value, codec: codec, message: message)
        let threshold = Self.hexThreshold
        let guessed =
            codec != nil && !storedAsJSON
            ? ValueFormat.protobuf
            : await Task.detached {
                kv.value.count > threshold ? ValueFormat.hex : ValueFormat.guess(for: kv.value)
            }.value
        let storedText = storedAsJSON ? String(decoding: kv.value, as: UTF8.self) : nil
        var check: SchemaCheck?
        if let storedText, let codec, let message {
            check = await Task.detached { MessageCheck.check(storedText, message: message, codec: codec) }.value
        }
        guard current == generation, !(keepingEdits && isDirty) else { return }
        self.mapping = mapping
        self.codec = codec
        schemaCheckTask?.cancel()
        isStoredAsJSON = storedAsJSON
        schemaCheck = check
        checkedText = storedText
        format = guessed
        adopt(kv, decoding: decoding)
    }

    // MARK: Editing

    /// The explicit command that loads a large value into the editor.
    public func openInEditor() {
        guard let loaded, mapping == .unmapped || isStoredAsJSON, String(data: loaded.value, encoding: .utf8) != nil
        else { return }
        editorOverride = true
        format = ValueFormat.guess(for: loaded.value)
    }

    /// Pretty-prints the buffer, keeping key order; works on invalid JSON too.
    public func formatJSON(_ formatter: JSONFormatter = JSONFormatter()) {
        guard isEditable else { return }
        text = formatter.prettyPrint(text)
    }

    public func minifyJSON() {
        guard isEditable else { return }
        text = JSONFormatter().minify(text)
    }

    // MARK: Saving

    /// A transaction on the loaded mod revision, never a bare put.
    public func save(to connection: ConnectionModel) async {
        // A second save would compare against the revision the first one replaces.
        if case .saving = saveState { return }
        guard let loaded, isEditable, isDirty else { return }
        await write(expecting: loaded.modRevision, base: loaded, to: connection)
    }

    /// After a conflict, writes the local edits over the value just seen.
    /// A key deleted meanwhile is recreated only if still absent.
    public func overwrite(to connection: ConnectionModel) async {
        guard case .conflict(let current) = saveState, let loaded else { return }
        let base = current ?? KeyValue(key: loaded.key)
        if let pendingRestore {
            await write(pendingRestore, expecting: base.modRevision, base: base, to: connection)
        } else if isEditable {
            await write(expecting: base.modRevision, base: base, to: connection)
        }
    }

    /// After a conflict, drops the local edits in favor of the store value.
    public func discardLocalEdits() {
        guard case .conflict(let current) = saveState else { return }
        pendingRestore = nil
        if let current {
            adopt(current, decoding: Self.decode(current.value, codec: codec, message: protobufMessage))
        } else {
            state = .missing
            saveState = .idle
        }
    }

    /// Closes the conflict without choosing; edits and baseline stay.
    public func cancelConflict() {
        guard case .conflict = saveState else { return }
        pendingRestore = nil
        saveState = .idle
    }

    /// After a conflict, puts both versions in the buffer with conflict
    /// markers; the next save compares against the store value.
    public func openMerge() {
        guard case .conflict(let current?) = saveState else { return }
        let local = pendingRestore.map(renderedText(for:)) ?? text
        adopt(current, decoding: Self.decode(current.value, codec: codec, message: protobufMessage))
        text = LineDiff.mergeView(local: local, remote: baselineText)
    }

    /// Writes an earlier version's bytes as a new value, guarded like any
    /// save; the buffer is left alone. See SPEC 4.7.
    public func restore(_ version: KeyValue, to connection: ConnectionModel) async {
        if case .saving = saveState { return }
        guard let loaded else { return }
        pendingRestore = version.value
        await write(version.value, expecting: loaded.modRevision, base: loaded, to: connection)
    }

    private func write(expecting revision: Int64, base: KeyValue, to connection: ConnectionModel) async {
        let data: Data
        do {
            data = try encodedBuffer()
        } catch {
            saveState = .failed(ConnectionModel.message(for: error))
            return
        }
        await write(data, expecting: revision, base: base, to: connection)
    }

    private func write(_ data: Data, expecting revision: Int64, base: KeyValue, to connection: ConnectionModel) async {
        guard connection.session == session else {
            pendingRestore = nil
            saveState = .failed(
                String(localized: "The connection changed since this value was loaded. Reopen the key to edit it.", bundle: .module))
            return
        }
        let sent = text
        saveState = .saving
        do {
            switch try await connection.save(
                key: base.key, value: data, expectedModRevision: revision, lease: base.lease)
            {
            case .written(let response):
                let written = response.header.revision
                let kv = KeyValue(
                    key: base.key, createRevision: revision == 0 ? written : base.createRevision,
                    modRevision: written, version: revision == 0 ? 1 : base.version + 1,
                    value: data, lease: base.lease)
                let decoding = await Self.decodeDetached(data, codec: codec, message: protobufMessage)
                // Text typed while the save was in flight stays, unsaved.
                let typed = text
                adopt(kv, decoding: decoding)
                if typed != sent { text = typed }
                saveState = .saved
            case .conflict(let current):
                saveState = .conflict(current: current)
            }
        } catch {
            pendingRestore = nil
            saveState = .failed(ConnectionModel.message(for: error))
        }
    }

    /// The bytes to write: the buffer as UTF-8, or the edited JSON encoded
    /// with the message descriptor, keeping the original's unknown fields.
    private func encodedBuffer() throws -> Data {
        guard let codec, let message = protobufMessage else { return Data(text.utf8) }
        return try codec.encodeFromJSON(text, messageName: message, originalBytes: loaded?.value)
    }

    // MARK: Presentation

    private func adopt(_ kv: KeyValue, decoding: Decoding?) {
        state = .loaded(kv)
        pendingRestore = nil
        switch decoding {
        case .decoded(let decoded):
            protobuf = decoded
            protobufError = nil
        case .failed(let message):
            protobuf = nil
            protobufError = message
        case nil:
            protobuf = nil
            protobufError = nil
        }
        // A mapped value that failed to decode offers no text at all, never
        // a partial message.
        baselineText = protobuf?.json ?? (protobufMessage == nil ? String(data: kv.value, encoding: .utf8) ?? "" : "")
        text = baselineText
        saveState = .idle
    }

    /// Checks the buffer against the mapped message once typing pauses.
    private func scheduleSchemaCheck() {
        schemaCheckTask?.cancel()
        guard let codec, let message = mappedMessage else { return }
        let text = self.text
        schemaCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let check = await Task.detached { MessageCheck.check(text, message: message, codec: codec) }.value
            guard !Task.isCancelled, let self, self.text == text else { return }
            self.checkedText = text
            self.schemaCheck = check
        }
    }

    /// Bytes as the editor shows them: a mapped message's JSON, else UTF-8.
    public func renderedText(for data: Data) -> String {
        if case .decoded(let decoded) = Self.decode(data, codec: codec, message: protobufMessage) {
            return decoded.json
        }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func decode(_ data: Data, codec: ProtobufValueCodec?, message: String?) -> Decoding? {
        guard let codec, let message else { return nil }
        do {
            return .decoded(try codec.decodeToJSON(data, messageName: message))
        } catch {
            return .failed(ConnectionModel.message(for: error))
        }
    }

    private static func decodeDetached(_ data: Data, codec: ProtobufValueCodec?, message: String?) async -> Decoding? {
        guard codec != nil else { return nil }
        return await Task.detached { decode(data, codec: codec, message: message) }.value
    }
}
