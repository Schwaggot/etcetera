import EtcdKit
import Foundation
import Observation

/// One node of the key tree. etcd has no directories; the tree comes from
/// splitting keys on the connection's separator. A node can hold a value and
/// have children at the same time, so both flags can be true.
@MainActor
@Observable
public final class KeyNode: Identifiable {
    public let name: String
    public let path: String
    public internal(set) var isLeaf: Bool
    public internal(set) var hasChildren: Bool
    /// Nil until first expanded; then all children, loaded page by page.
    public internal(set) var children: [KeyNode]?
    public internal(set) var isLoading = false
    /// Paging stopped before the last page, so children may be missing.
    var moreAvailable = false

    public nonisolated var id: String { path }

    init(name: String, path: String, isLeaf: Bool, hasChildren: Bool) {
        self.name = name
        self.path = path
        self.isLeaf = isLeaf
        self.hasChildren = hasChildren
    }

    convenience init(_ node: TreeNode) {
        self.init(name: node.name, path: node.path, isLeaf: node.isLeaf, hasChildren: node.hasChildren)
    }

    /// The synthetic root; its children are the top of the tree.
    static func root() -> KeyNode {
        KeyNode(name: "", path: "", isLeaf: false, hasChildren: true)
    }

    /// Later pages can revisit a segment from an earlier page, so children
    /// are merged by path with flags combined, never replaced. Children stay
    /// in byte order, as etcd sorts keys, when live updates add some.
    func merge(_ nodes: [TreeNode]) {
        var merged = children ?? []
        var indexByPath = [String: Int]()
        for (index, child) in merged.enumerated() {
            indexByPath[child.path] = index
        }
        for incoming in nodes {
            if let index = indexByPath[incoming.path] {
                merged[index].isLeaf = merged[index].isLeaf || incoming.isLeaf
                merged[index].hasChildren = merged[index].hasChildren || incoming.hasChildren
            } else {
                indexByPath[incoming.path] = merged.count
                merged.append(KeyNode(incoming))
            }
        }
        merged.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        children = merged
    }
}
