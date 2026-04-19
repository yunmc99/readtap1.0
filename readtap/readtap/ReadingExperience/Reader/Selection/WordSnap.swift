import CoreGraphics

enum WordSnap {
    struct Item<Value> {
        let value: Value
        let rect: CGRect
    }

    static func pickLineFirst<Value>(
        point: CGPoint,
        items: [Item<Value>],
        accept: (CGFloat, CGRect) -> Bool
    ) -> Item<Value>? {
        let filtered = items.filter { !$0.rect.isNull && !$0.rect.isEmpty }
        guard !filtered.isEmpty else { return nil }

        let heights = filtered
            .map { $0.rect.height }
            .filter { $0 > 0 }
            .sorted()
        guard let medianHeight = heights.isEmpty ? nil : heights[heights.count / 2] else {
            return nearestAccepted(point: point, items: filtered, accept: accept)
        }

        let mergeThreshold = max(0, medianHeight * 0.65)
        let maxLineDistance = max(0, medianHeight * 3.0)

        let lines = buildLines(items: filtered, mergeThreshold: mergeThreshold)
        guard !lines.isEmpty else {
            return nearestAccepted(point: point, items: filtered, accept: accept)
        }

        let sortedLines = lines.sorted { verticalDistance(from: point.y, to: $0.yMin, $0.yMax) < verticalDistance(from: point.y, to: $1.yMin, $1.yMax) }

        // Try the closest few lines first. If selection isn't close enough, fall back to global nearest.
        for line in sortedLines.prefix(3) {
            let lineDistance = verticalDistance(from: point.y, to: line.yMin, line.yMax)
            if lineDistance > maxLineDistance {
                continue
            }
            if let candidate = bestInLine(point: point, line: line), accept(distance(point, candidate.rect), candidate.rect) {
                return candidate
            }
        }

        return nearestAccepted(point: point, items: filtered, accept: accept)
    }

    // MARK: - Internals

    private struct Line<Value> {
        var items: [Item<Value>]
        var yMin: CGFloat
        var yMax: CGFloat
        var midY: CGFloat

        init(item: Item<Value>) {
            items = [item]
            yMin = item.rect.minY
            yMax = item.rect.maxY
            midY = item.rect.midY
        }

        mutating func add(_ item: Item<Value>) {
            items.append(item)
            yMin = min(yMin, item.rect.minY)
            yMax = max(yMax, item.rect.maxY)
            midY = (yMin + yMax) / 2
        }
    }

    private static func buildLines<Value>(items: [Item<Value>], mergeThreshold: CGFloat) -> [Line<Value>] {
        var lines: [Line<Value>] = []

        for item in items.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            var bestIndex: Int?
            var bestDelta: CGFloat = .greatestFiniteMagnitude
            for idx in lines.indices {
                let delta = abs(lines[idx].midY - item.rect.midY)
                if delta < bestDelta {
                    bestDelta = delta
                    bestIndex = idx
                }
            }

            if let idx = bestIndex, bestDelta <= mergeThreshold {
                lines[idx].add(item)
            } else {
                lines.append(Line(item: item))
            }
        }

        for idx in lines.indices {
            lines[idx].items.sort { $0.rect.minX < $1.rect.minX }
        }
        return lines
    }

    private static func bestInLine<Value>(point: CGPoint, line: Line<Value>) -> Item<Value>? {
        if let contained = line.items.filter({ $0.rect.contains(point) }).min(by: { area($0.rect) < area($1.rect) }) {
            return contained
        }
        return line.items.min(by: { distance(point, $0.rect) < distance(point, $1.rect) })
    }

    private static func nearestAccepted<Value>(
        point: CGPoint,
        items: [Item<Value>],
        accept: (CGFloat, CGRect) -> Bool
    ) -> Item<Value>? {
        let sorted = items
            .map { ($0, distance(point, $0.rect)) }
            .sorted(by: { $0.1 < $1.1 })
        for (item, dist) in sorted {
            if accept(dist, item.rect) {
                return item
            }
        }
        return nil
    }

    private static func verticalDistance(from y: CGFloat, to minY: CGFloat, _ maxY: CGFloat) -> CGFloat {
        if y < minY { return minY - y }
        if y > maxY { return y - maxY }
        return 0
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}

