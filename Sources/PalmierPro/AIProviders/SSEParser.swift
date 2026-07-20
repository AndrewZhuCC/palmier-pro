import Foundation

struct SSEEvent: Sendable, Equatable {
    let event: String?
    let id: String?
    let data: String
    let retryMilliseconds: Int?
}

struct SSEParser: Sendable {
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: Int?

    mutating func consume(line rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            let remainder = line[line.index(after: colon)...]
            value = remainder.first == " " ? String(remainder.dropFirst()) : String(remainder)
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id" where !value.contains("\0"): eventID = value
        case "retry": retryMilliseconds = Int(value)
        default: break
        }
        return nil
    }

    mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            eventName = nil
            retryMilliseconds = nil
            return nil
        }
        let event = SSEEvent(
            event: eventName,
            id: eventID,
            data: dataLines.joined(separator: "\n"),
            retryMilliseconds: retryMilliseconds
        )
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        retryMilliseconds = nil
        return event
    }
}
