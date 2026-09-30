import Foundation

/// A B-tree stored in the heap.
///
/// Node layout (all big-endian):
/// ```
/// +0  u32 parent block (0 for root)
/// +4  u32 leftmost child block (0 for leaf)
/// +8  u32 own block number (self check)
/// +12 u16 info
/// +14 u16 node size in bytes (0x400 / 0x800)
/// +16 u16 entry count
/// +18 u16 lowest key offset (keys grow downward from the node end)
/// +20 entries[count] = { u32 value, u32 right child block, u16 key offset }
/// ```
/// Keys live at `node + keyOffset` as `[u8 length][bytes]`. Values are block
/// numbers (primary record tree) or record ids (secondary indexes).
public struct BTree {
    public struct Entry {
        public let key: ArraySlice<UInt8>
        public let value: UInt32
    }

    let heap: HeapFile
    public let root: UInt32

    public init(heap: HeapFile, root: UInt32) {
        self.heap = heap
        self.root = root
    }

    /// In-order traversal of every entry in the tree.
    public func entries() throws -> [Entry] {
        var out: [Entry] = []
        var visited = Set<UInt32>()
        try visit(root, depth: 0, visited: &visited, into: &out)
        return out
    }

    private func visit(_ block: UInt32, depth: Int, visited: inout Set<UInt32>, into out: inout [Entry]) throws {
        guard depth < 64 else { throw HelixFormatError("B-tree too deep (corrupt?).") }
        guard heap.isValidBlock(block), visited.insert(block).inserted else {
            throw HelixFormatError("Invalid or cyclic B-tree node at block \(block).")
        }
        let o = heap.offset(ofBlock: block)
        guard heap.u32(o + 8) == block else { throw HelixFormatError("B-tree node self-check failed at block \(block).") }
        let left = heap.u32(o + 4)
        let size = Int(heap.u16(o + 14))
        let count = Int(heap.u16(o + 16))
        guard 20 + count * 10 <= size, o + size <= heap.bytes.count else {
            throw HelixFormatError("B-tree node at block \(block) overruns.")
        }
        if left != 0 { try visit(left, depth: depth + 1, visited: &visited, into: &out) }
        for i in 0..<count {
            let e = o + 20 + i * 10
            let value = heap.u32(e)
            let right = heap.u32(e + 4)
            let keyOff = Int(heap.u16(e + 8))
            let keyLen = Int(heap.u8(o + keyOff))
            out.append(Entry(key: heap.slice(o + keyOff + 1, keyLen), value: value))
            if right != 0 { try visit(right, depth: depth + 1, visited: &visited, into: &out) }
        }
    }
}
