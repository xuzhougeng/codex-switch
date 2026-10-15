import Foundation

/// One live connection with derived rates, ready for display.
public struct ConnectionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let host: String
    public let destinationPort: String
    public let network: String
    public let process: String
    public let rule: String
    public let chains: [String]
    public let exit: String
    public let upload: Int64
    public let download: Int64
    public let rateUp: Int
    public let rateDown: Int
    public let age: TimeInterval
    public let lastActive: Date
    public var isDirect: Bool { exit == "DIRECT" }
    public var isRejected: Bool { exit == "REJECT" }
}

/// Cumulative traffic for one destination, across every connection seen this session.
public struct HostAggregate: Identifiable, Equatable, Sendable {
    public var id: String { host }
    public let host: String
    public let opened: Int
    public let active: Int
    public let upload: Int64
    public let download: Int64
    public let rule: String
    public let exits: [String]
}

/// Cumulative traffic for one exit (node, DIRECT, REJECT), across every connection seen this session.
public struct ExitAggregate: Identifiable, Equatable, Sendable {
    public var id: String { exit }
    public let exit: String
    public let opened: Int
    public let active: Int
    public let upload: Int64
    public let download: Int64
    public let hosts: [String]
}

public struct TrafficSnapshot: Equatable, Sendable {
    public var rateUp = 0
    public var rateDown = 0
    public var sessionUp: Int64 = 0
    public var sessionDown: Int64 = 0
    public var rows: [ConnectionRow] = []
    public var byHost: [HostAggregate] = []
    public var byExit: [ExitAggregate] = []
    public init() {}
}

/// Turns successive `/connections` snapshots into rates and session totals.
///
/// mihomo only reports active connections, so a connection that vanishes from one
/// snapshot to the next is finalized here with its last-seen byte counts. That makes
/// the aggregates survive proxy restarts (every connection closes at once) and keeps
/// working after the service stops, until `clear()`.
public struct ConnectionTracker: Sendable {
    private struct Record {
        var host: String
        var destinationPort: String
        var network: String
        var process: String
        var rule: String
        var exit: String
        var chains: [String]
        var upload: Int64
        var download: Int64
        var started: Date?
        var lastActive: Date
        var rateUp = 0
        var rateDown = 0
        var closed = false
    }

    private var records: [String: Record] = [:]
    private var lastAt: Date?
    private var lastTotals: (up: Int64, down: Int64)?
    private var rateUp = 0
    private var rateDown = 0
    private let hostLimit: Int
    private let closedLimit: Int

    public init(hostLimit: Int = 500, closedLimit: Int = 2000) {
        self.hostLimit = hostLimit
        self.closedLimit = closedLimit
    }

    public var isEmpty: Bool { records.isEmpty && rateUp == 0 && rateDown == 0 }

    public mutating func clear() {
        records.removeAll()
        lastAt = nil
        lastTotals = nil
        rateUp = 0
        rateDown = 0
    }

    /// The service is down: every live connection is gone for good. Finalize them;
    /// history stays visible until `clear()`.
    public mutating func markStopped() {
        rateUp = 0
        rateDown = 0
        lastTotals = nil
        for id in records.keys {
            records[id]!.closed = true
            records[id]!.rateUp = 0
            records[id]!.rateDown = 0
        }
    }

    /// Current aggregates without new data (e.g. after `markStopped()`).
    public mutating func snapshot() -> TrafficSnapshot {
        build(now: Date())
    }

    public mutating func ingest(_ snapshot: ProxyConnections, at now: Date) -> TrafficSnapshot {
        let dt = max(now.timeIntervalSince(lastAt ?? now), 0.2)
        // Kernel totals reset on restart; a negative diff just means "start over".
        if let previous = lastTotals {
            rateUp = smooth(rateUp, delta(snapshot.uploadTotal, previous.up), dt)
            rateDown = smooth(rateDown, delta(snapshot.downloadTotal, previous.down), dt)
        }
        lastTotals = (snapshot.uploadTotal, snapshot.downloadTotal)
        lastAt = now

        let live = snapshot.connections ?? []
        var seen = Set<String>()
        seen.reserveCapacity(live.count)
        for connection in live {
            seen.insert(connection.id)
            let upload = connection.upload ?? 0
            let download = connection.download ?? 0
            let host = connection.destination
            let exit = connection.exit
            if var record = records[connection.id] {
                record.rateUp = smooth(record.rateUp, delta(upload, record.upload), dt)
                record.rateDown = smooth(record.rateDown, delta(download, record.download), dt)
                if upload != record.upload || download != record.download { record.lastActive = now }
                // The host starts as an IP and fills in once DNS resolves; keep the refined value.
                record.host = host
                record.upload = upload
                record.download = download
                record.closed = false
                records[connection.id] = record
            } else {
                records[connection.id] = Record(
                    host: host,
                    destinationPort: connection.metadata.destinationPort ?? "",
                    network: (connection.metadata.network ?? "").uppercased(),
                    process: connection.metadata.process ?? "",
                    rule: Self.ruleText(connection), exit: exit, chains: connection.chains ?? [],
                    upload: upload, download: download, started: Self.parseStart(connection.start) ?? now,
                    lastActive: now)
            }
        }
        for (id, _) in records where !seen.contains(id) {
            records[id]!.closed = true
            records[id]!.rateUp = 0
            records[id]!.rateDown = 0
        }
        trim()
        return build(now: now)
    }

    /// Exponential smoothing with α = 0.5; a fresh track starts at the measured rate.
    private func smooth(_ previous: Int, _ measured: Int, _ dt: TimeInterval) -> Int {
        guard measured > 0 || previous > 0 else { return 0 }
        let value = Double(measured) / dt
        return previous == 0 ? Int(value) : Int((Double(previous) + value) / 2)
    }

    private func delta(_ current: Int64, _ previous: Int64) -> Int {
        current > previous ? Int(current - previous) : 0
    }

    private static func ruleText(_ connection: ProxyConnections.Connection) -> String {
        [connection.rule ?? "", connection.rulePayload ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private static func parseStart(_ text: String?) -> Date? {
        guard let text else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    /// Bound memory: drop the smallest closed records, then merge overflow hosts.
    private mutating func trim() {
        let closed = records.filter { $0.value.closed }
        if closed.count > closedLimit {
            let dropped = closed
                .sorted { ($0.value.upload + $0.value.download) < ($1.value.upload + $1.value.download) }
                .prefix(closed.count - closedLimit)
            for (id, _) in dropped { records[id] = nil }
        }
        var hosts = Set(records.values.map(\.host))
        if hosts.count > hostLimit {
            var traffic: [String: Int64] = [:]
            for record in records.values { traffic[record.host, default: 0] += record.upload + record.download }
            let keep = Set(traffic.sorted { $0.value > $1.value }.prefix(hostLimit).map(\.key))
            for (id, record) in records where !keep.contains(record.host) { records[id] = nil }
            hosts = keep
        }
    }

    private func build(now: Date) -> TrafficSnapshot {
        var result = TrafficSnapshot()
        result.rateUp = rateUp
        result.rateDown = rateDown
        struct HostStats { var opened = 0; var active = 0; var upload: Int64 = 0; var download: Int64 = 0; var ruleTraffic: [String: Int64] = [:]; var exitTraffic: [String: Int64] = [:] }
        struct ExitStats { var opened = 0; var active = 0; var upload: Int64 = 0; var download: Int64 = 0; var hosts: [String: Int64] = [:] }
        var hosts: [String: HostStats] = [:]
        var exits: [String: ExitStats] = [:]
        for record in records.values {
            result.sessionUp += record.upload
            result.sessionDown += record.download
            let bytes = record.upload + record.download
            var host = hosts[record.host, default: HostStats()]
            host.opened += 1
            host.upload += record.upload
            host.download += record.download
            if !record.closed { host.active += 1 }
            if !record.rule.isEmpty { host.ruleTraffic[record.rule, default: 0] += bytes }
            if !record.exit.isEmpty { host.exitTraffic[record.exit, default: 0] += bytes }
            hosts[record.host] = host
            var exit = exits[record.exit.isEmpty ? "未知" : record.exit, default: ExitStats()]
            exit.opened += 1
            exit.upload += record.upload
            exit.download += record.download
            if !record.closed { exit.active += 1 }
            exit.hosts[record.host, default: 0] += bytes
            exits[record.exit.isEmpty ? "未知" : record.exit] = exit
        }
        result.rows = records.filter { !$0.value.closed }.map { id, record in
            ConnectionRow(
                id: id, host: record.host, destinationPort: record.destinationPort,
                network: record.network, process: record.process, rule: record.rule,
                chains: record.chains, exit: record.exit,
                upload: record.upload, download: record.download,
                rateUp: record.rateUp, rateDown: record.rateDown,
                age: max(0, now.timeIntervalSince(record.started ?? now)), lastActive: record.lastActive)
        }
        result.rows.sort { $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : ($0.upload + $0.download) > ($1.upload + $1.download) }
        result.byHost = hosts.map { host, stats in
            HostAggregate(host: host, opened: stats.opened, active: stats.active, upload: stats.upload, download: stats.download,
                          rule: stats.ruleTraffic.sorted { $0.value > $1.value }.first?.key ?? "",
                          exits: stats.exitTraffic.sorted { $0.value > $1.value }.prefix(3).map(\.key))
        }
        result.byHost.sort { ($0.upload + $0.download) > ($1.upload + $1.download) }
        result.byExit = exits.map { exit, stats in
            ExitAggregate(exit: exit, opened: stats.opened, active: stats.active, upload: stats.upload, download: stats.download,
                          hosts: stats.hosts.sorted { $0.value > $1.value }.prefix(3).map(\.key))
        }
        result.byExit.sort { ($0.upload + $0.download) > ($1.upload + $1.download) }
        return result
    }
}
