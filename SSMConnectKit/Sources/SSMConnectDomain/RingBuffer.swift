import Foundation

/// A fixed-capacity FIFO buffer that keeps only the most recent `capacity` elements (H2, F-19).
/// Appending past capacity drops the oldest element. Order is oldest → newest.
public struct RingBuffer<Element> {
    public private(set) var elements: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    public var count: Int { elements.count }
    public var isFull: Bool { elements.count >= capacity }

    public mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }

    public mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
    }
}
