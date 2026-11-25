import Foundation
import SSMConnectDomain

/// A fixed-capacity FIFO buffer that keeps only the most recent `capacity` elements (H2, F-19).
/// Appending past capacity drops the oldest element. Order is oldest → newest.
package struct RingBuffer<Element> {
    package private(set) var elements: [Element] = []
    package let capacity: Int

    package init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    package var count: Int { elements.count }
    package var isFull: Bool { elements.count >= capacity }

    package mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }

    package mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
    }
}
