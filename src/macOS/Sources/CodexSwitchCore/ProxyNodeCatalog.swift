import Foundation

/// Parse once per subscription. Rendering, searching and delay updates reuse this index.
public struct ProxyNodeCatalog: Sendable {
    public let names: [String]
    public let exitNames: [String]
    private let positions: [String: Int]

    public init(yaml: String = "") {
        names = DialerProxyBuilder.extractRelayNames(yaml)
        exitNames = DialerProxyBuilder.withoutHongKong(names)
        positions = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
    }

    public func candidates(for route: ProxyRoute) -> [String] { route == .relay ? names : exitNames }

    public func visibleNodes(route: ProxyRoute, search: String, delays: [String: Int]) -> [String] {
        let candidates = candidates(for: route)
        let filtered = search.isEmpty ? candidates : candidates.filter { $0.localizedCaseInsensitiveContains(search) }
        guard !delays.isEmpty else { return filtered }
        return filtered.sorted {
            let a = delays[$0].flatMap { $0 < 0 ? nil : $0 } ?? Int.max
            let b = delays[$1].flatMap { $0 < 0 ? nil : $0 } ?? Int.max
            return a == b ? positions[$0, default: 0] < positions[$1, default: 0] : a < b
        }
    }
}
