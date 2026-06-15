import Foundation
import Testing
@testable import SSMConnectKit

@Suite("RingBuffer")
struct RingBufferTests {
    @Test("keeps elements in append order below capacity")
    func ordering() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 1...3 { buffer.append(value) }
        #expect(buffer.elements == [1, 2, 3])
        #expect(buffer.count == 3)
        #expect(buffer.isFull == false)
    }

    @Test("drops the oldest elements past capacity")
    func dropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...6 { buffer.append(value) }
        #expect(buffer.elements == [4, 5, 6])
        #expect(buffer.count == 3)
        #expect(buffer.isFull)
    }

    @Test("capacity is clamped to at least 1")
    func minimumCapacity() {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.elements == [2])
    }

    @Test("removeAll empties the buffer")
    func removeAll() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.removeAll()
        #expect(buffer.elements.isEmpty)
        #expect(buffer.count == 0)
    }
}

@Suite("ConnectionLog")
@MainActor
struct ConnectionLogTests {
    @Test("log appends entries with the given category and message")
    func appends() {
        let log = ConnectionLog(now: { Date(timeIntervalSince1970: 0) })
        log.log(.tunnel, "opened")
        log.log(.ec2, "resolved")

        #expect(log.entries.count == 2)
        #expect(log.entries[0].category == .tunnel)
        #expect(log.entries[0].message == "opened")
        #expect(log.entries[1].category == .ec2)
    }

    @Test("log is capped at capacity, keeping the newest entries")
    func capacity() {
        let log = ConnectionLog(capacity: 3)
        for index in 1...5 { log.log(.ui, "m\(index)") }

        #expect(log.entries.count == 3)
        #expect(log.entries.map(\.message) == ["m3", "m4", "m5"])
    }

    @Test("clear empties the log")
    func clear() {
        let log = ConnectionLog()
        log.log(.ui, "x")
        log.clear()
        #expect(log.entries.isEmpty)
    }
}

@Suite("NotificationEvent")
struct NotificationEventTests {
    @Test("each event has a non-empty title and body")
    func contents() {
        let events: [NotificationEvent] = [.connected, .stopped, .reconnecting, .signInRequired]
        for event in events {
            #expect(!event.title.isEmpty)
            #expect(!event.body.isEmpty)
        }
    }
}
