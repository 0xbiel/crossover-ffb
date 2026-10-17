public enum HatDirection: String, Equatable, Sendable {
    case north = "↑ Up", northEast = "↗ Up-right", east = "→ Right", southEast = "↘ Down-right"
    case south = "↓ Down", southWest = "↙ Down-left", west = "← Left", northWest = "↖ Up-left"
    case neutral = "• Neutral", unknown = "? Unknown"
    public static func decode(raw: Int, minimum: Int, maximum: Int, hasNullState: Bool) -> Self {
        guard maximum >= minimum else { return .unknown }
        if raw < minimum || raw > maximum { return hasNullState ? .neutral : .unknown }
        // Interpret only the conventional eight-position HID hat, never clamp neutral to a direction.
        guard Double(maximum) - Double(minimum) == 7 else { return .unknown }
        return [.north, .northEast, .east, .southEast, .south, .southWest, .west, .northWest][raw - minimum]
    }
}
