import Foundation

public enum Layer: Int, CaseIterable, Codable, Sendable, Comparable {
    case drone, pad, bass, drums, melody, field

    public static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .drone: "Drone"
        case .pad: "Pads"
        case .bass: "Bass"
        case .drums: "Drums"
        case .melody: "Melody"
        case .field: "Field recording"
        }
    }

    /// Share of the daily target needed to unlock this layer.
    public var unlockFraction: Double {
        switch self {
        case .drone: 0
        case .pad: 0.08
        case .bass: 0.25
        case .drums: 0.42
        case .melody: 0.67
        case .field: 1.0
        }
    }
}

public struct LayerSchedule: Sendable, Equatable {
    public var targetMinutes: Double

    public init(targetMinutes: Double) {
        self.targetMinutes = max(1, targetMinutes)
    }

    public func threshold(_ layer: Layer) -> Double { layer.unlockFraction * targetMinutes }

    public func unlocked(minutes: Double) -> Set<Layer> {
        Set(Layer.allCases.filter { minutes + 1e-9 >= threshold($0) })
    }

    public func highest(minutes: Double) -> Layer {
        unlocked(minutes: minutes).max() ?? .drone
    }

    /// Next layer to unlock and minutes remaining, or nil when the song is complete.
    public func next(minutes: Double) -> (layer: Layer, remaining: Double)? {
        for layer in Layer.allCases where minutes + 1e-9 < threshold(layer) {
            return (layer, threshold(layer) - minutes)
        }
        return nil
    }

    public func progress(minutes: Double) -> Double { min(1, max(0, minutes / targetMinutes)) }
}

/// Maps running cadence to a musical tempo.
public enum CadenceTempo {
    public static let range: ClosedRange<Double> = 80...170

    /// Steps per minute to BPM, folded by octaves into a comfortable range.
    public static func bpm(stepsPerMinute spm: Double) -> Double? {
        guard spm >= 60, spm.isFinite else { return nil }
        var x = spm
        while x > range.upperBound { x /= 2 }
        while x < range.lowerBound { x *= 2 }
        return x
    }
}
