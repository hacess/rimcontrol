import Foundation

public enum LevelStep {
    /// The level after moving by `delta`: snapped to `grid`, then kept between 0 and `limit`.
    public static func next(current: Double, delta: Double, grid: Double, limit: Double = 1) -> Double {
        let snapped = ((current + delta) / grid).rounded() * grid
        return min(max(snapped, 0), min(limit, 1))
    }
}
