import Foundation

/// Solar position using the NOAA general solar position equations.
/// Accurate to well under a degree, which is plenty for "is it light out".
public enum Solar {
    /// Sun elevation above the horizon in degrees. Negative means below.
    public static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let t = (jd - 2451545.0) / 36525.0

        let l0 = mod(280.46646 + t * (36000.76983 + t * 0.0003032), 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let mr = rad(m)

        let center = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * mr) * (0.019993 - 0.000101 * t)
            + sin(3 * mr) * 0.000289
        let trueLong = l0 + center
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLong - 0.00569 - 0.00478 * sin(rad(omega))

        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let decl = asin(sin(rad(eps)) * sin(rad(lambda)))

        let y = pow(tan(rad(eps) / 2), 2)
        let l0r = rad(l0)
        let eqTime = 4 * deg(
            y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
                - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr))

        let utcMinutes = mod(date.timeIntervalSince1970, 86400) / 60
        let trueSolarTime = mod(utcMinutes + eqTime + 4 * longitude, 1440)
        let hourAngle = trueSolarTime / 4 - 180

        let latR = rad(latitude)
        let cosZenith = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(rad(hourAngle))
        let zenith = acos(min(1, max(-1, cosZenith)))
        return 90 - deg(zenith)
    }

    /// Civil twilight: light enough to be outside without a torch.
    public static let civilTwilight = -6.0

    public static func isLight(at date: Date, latitude: Double, longitude: Double) -> Bool {
        elevation(at: date, latitude: latitude, longitude: longitude) > civilTwilight
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
    private static func mod(_ a: Double, _ n: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: n)
        return r < 0 ? r + n : r
    }
}
