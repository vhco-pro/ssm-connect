import Foundation

/// A fixed-capacity FIFO buffer that keeps only the most recent `capacity` elements (H2, F-19).
/// Appending past capacity drops the oldest element. Order is oldest → newest.
struct RingBuffer<Element> {
    private(set) var elements: [Element] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    var count: Int { elements.count }
    var isFull: Bool { elements.count >= capacity }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }

    mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
    }
}
