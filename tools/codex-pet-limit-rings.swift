import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore
import SQLite3

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }

    func isVisuallyEquivalent(to other: LimitBucket) -> Bool {
        Self.close(remainingPercent, other.remainingPercent, tolerance: 0.05) &&
            Self.close(windowMinutes, other.windowMinutes, tolerance: 0.5) &&
            Self.close(resetAt, other.resetAt, tolerance: 1.0)
    }

    private static func close(_ lhs: Double?, _ rhs: Double?, tolerance: Double) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return close(lhs, rhs, tolerance: tolerance)
        default:
            return false
        }
    }

    private static func close(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

struct LimitState {
    var planType: String?
    var primary: LimitBucket?
    var secondary: LimitBucket?
    var additional: [(name: String, bucket: LimitBucket)]
    var observedAt: Date
    var source: String

    var hasLimitData: Bool {
        primary != nil || secondary != nil || !additional.isEmpty
    }

    func isVisuallyEquivalent(to other: LimitState) -> Bool {
        guard Self.bucket(primary, isVisuallyEquivalentTo: other.primary),
              Self.bucket(secondary, isVisuallyEquivalentTo: other.secondary),
              additional.count == other.additional.count else {
            return false
        }

        return zip(additional, other.additional).allSatisfy { lhs, rhs in
            lhs.name == rhs.name && lhs.bucket.isVisuallyEquivalent(to: rhs.bucket)
        }
    }

    private static func bucket(_ lhs: LimitBucket?, isVisuallyEquivalentTo rhs: LimitBucket?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.isVisuallyEquivalent(to: rhs)
        default:
            return false
        }
    }

    static let empty = LimitState(planType: nil, primary: nil, secondary: nil, additional: [], observedAt: Date(), source: "none")
}

private let limitStatePollInterval: TimeInterval = 20.0
private let petFrameFallbackPollInterval: TimeInterval = 2.0
private let petFrameStateDebounceInterval: TimeInterval = 0.035
private let dragFollowInterval: TimeInterval = 1.0 / 60.0
private let dragLiveMismatchTolerance: CGFloat = 96.0
private let panelFrameUpdateTolerance: CGFloat = 0.5
private let overlayWindowMatchRefreshInterval: TimeInterval = 12.0
private let petVisualCenterYOffsetFraction: CGFloat = 0.0
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let ringStyleDefaultsKey = "CodexPetLimitRings.ringStyle"
private let pixelCloudEnabledDefaultsKey = "CodexPetLimitRings.pixelCloudEnabled"
private let orbitGlintsEnabledDefaultsKey = "CodexPetLimitRings.orbitGlintsEnabled"
private let liveUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
private let fallbackPanelLevel = NSWindow.Level.statusBar

private enum LimitRingRole {
    case primary
    case secondary
}

private func limitRingColor(forRemaining remaining: Double, role: LimitRingRole) -> NSColor {
    if remaining <= 12 {
        return NSColor(calibratedRed: 1.00, green: 0.26, blue: 0.22, alpha: 0.96)
    }
    if remaining <= 30 {
        return NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 0.96)
    }
    if role == .secondary {
        return NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.00, alpha: 0.90)
    }
    return NSColor(calibratedRed: 0.24, green: 0.92, blue: 0.74, alpha: 0.96)
}

private func polarPoint(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
    CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
}

private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
    let clampedX = min(max(point.x, rect.minX), rect.maxX)
    let clampedY = min(max(point.y, rect.minY), rect.maxY)
    let dx = point.x - clampedX
    let dy = point.y - clampedY
    return dx * dx + dy * dy
}

private func distanceSquaredFromCenter(_ point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = point.x - rect.midX
    let dy = point.y - rect.midY
    return dx * dx + dy * dy
}

private func formatUsagePercent(_ percent: Double) -> String {
    if abs(percent.rounded() - percent) < 0.05 {
        return "\(Int(percent.rounded()))%"
    }
    return String(format: "%.1f%%", percent)
}

enum RingStyle: String, CaseIterable {
    case segmentedPixel = "segmented-pixel"
    case classicGlow = "classic-glow"
    case crtGlow = "crt-glow"

    var menuTitle: String {
        switch self {
        case .segmentedPixel:
            return "Segmented Pixel"
        case .classicGlow:
            return "Classic Glow"
        case .crtGlow:
            return "CRT Glow"
        }
    }

    var usesOrbitHighlights: Bool {
        true
    }

    var outerOrbitOffset: CGFloat {
        switch self {
        case .segmentedPixel:
            return 9.0
        case .classicGlow:
            return 5.0
        case .crtGlow:
            return 7.0
        }
    }

    var innerOrbitOffset: CGFloat {
        switch self {
        case .segmentedPixel:
            return -8.0
        case .classicGlow:
            return -5.0
        case .crtGlow:
            return -6.0
        }
    }

    var outerOrbitDuration: CFTimeInterval {
        switch self {
        case .segmentedPixel:
            return 4.6
        case .classicGlow:
            return 4.0
        case .crtGlow:
            return 4.8
        }
    }

    var innerOrbitDuration: CFTimeInterval {
        switch self {
        case .segmentedPixel:
            return 6.4
        case .classicGlow:
            return 5.4
        case .crtGlow:
            return 6.0
        }
    }

    var dustFieldBirthRate: Float {
        switch self {
        case .segmentedPixel:
            return 18.0
        case .classicGlow:
            return 16.0
        case .crtGlow:
            return 16.0
        }
    }

    var dustFieldLifetime: Float {
        switch self {
        case .segmentedPixel:
            return 6.6
        case .classicGlow:
            return 7.2
        case .crtGlow:
            return 6.0
        }
    }

    var dustFieldVelocity: CGFloat {
        switch self {
        case .segmentedPixel:
            return 2.4
        case .classicGlow:
            return 2.0
        case .crtGlow:
            return 2.6
        }
    }

    var dustFieldScale: CGFloat {
        switch self {
        case .segmentedPixel:
            return 0.58
        case .classicGlow:
            return 0.64
        case .crtGlow:
            return 0.50
        }
    }

    var dustFieldAlpha: CGFloat {
        switch self {
        case .segmentedPixel:
            return 0.105
        case .classicGlow:
            return 0.09
        case .crtGlow:
            return 0.10
        }
    }

    var dustFieldRingInset: CGFloat {
        switch self {
        case .segmentedPixel:
            return 16.0
        case .classicGlow, .crtGlow:
            return 17.0
        }
    }

    var dustFieldRadiusOutset: CGFloat {
        switch self {
        case .segmentedPixel:
            return 10.5
        case .classicGlow:
            return 11.5
        case .crtGlow:
            return 10.5
        }
    }
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
    var additional_rate_limits: [String: RatePayload]?
}

private struct AuthPayload: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var access_token: String?
}

private struct UsagePayload: Decodable {
    var plan_type: String?
    var rate_limit: RatePayload?
    var additional_rate_limits: [AdditionalUsagePayload]?
}

private struct AdditionalUsagePayload: Decodable {
    var limit_name: String?
    var metered_feature: String?
    var rate_limit: RatePayload?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else { return nil }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var authPath: URL
    var previewPath: URL?
    var ringStyle: RingStyle = .segmentedPixel
    var fallbackSize: CGFloat = 220
}

final class LimitStateReader {
    private let logsPath: URL
    private let authPath: URL
    private let session: URLSession

    init(logsPath: URL, authPath: URL) {
        self.logsPath = logsPath
        self.authPath = authPath
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func readLatest() -> LimitState {
        if let liveState = readLiveUsage() {
            return liveState
        }
        return readLatestLog()
    }

    private func readLiveUsage() -> LimitState? {
        guard let token = readAccessToken() else {
            return nil
        }

        var request = URLRequest(url: liveUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        session.dataTask(with: request) { data, response, _ in
            resultData = data
            resultResponse = response
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 7.0) == .success,
              let http = resultResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data = resultData,
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: data) else {
            return nil
        }

        let primary = (payload.rate_limit?.primary ?? payload.rate_limit?.primary_window)?.toBucket()
        let secondary = (payload.rate_limit?.secondary ?? payload.rate_limit?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [])
            .compactMap { item -> (String, LimitBucket)? in
                guard let bucket = (item.rate_limit?.primary ?? item.rate_limit?.primary_window ?? item.rate_limit?.secondary ?? item.rate_limit?.secondary_window)?.toBucket() else {
                    return nil
                }
                return (item.limit_name ?? item.metered_feature ?? "Additional", bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "live")
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authPath),
              let payload = try? JSONDecoder().decode(AuthPayload.self, from: data),
              let token = payload.tokens?.access_token,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return .empty
        }

        let body = String(cString: cText)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return .empty
        }

        let primary = (payload.rate_limits?.primary ?? payload.rate_limits?.primary_window)?.toBucket()
        let secondary = (payload.rate_limits?.secondary ?? payload.rate_limits?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [:])
            .compactMap { name, payload -> (String, LimitBucket)? in
                guard let bucket = (payload.primary ?? payload.primary_window ?? payload.secondary ?? payload.secondary_window)?.toBucket() else {
                    return nil
                }
                return (name, bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "log")
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = body.index(after: index)
                        break
                    }
                }
            }
            index = body.index(after: index)
        }

        guard let endIndex else { return nil }
        return String(body[start..<endIndex])
    }
}

struct PetFramesTopLeft {
    var mascot: CGRect
    var overlay: CGRect
    var displayId: CGDirectDisplayID?
    var usedLiveOverlay: Bool
}

final class PetFrameReader {
    private let globalStatePath: URL

    init(globalStatePath: URL) {
        self.globalStatePath = globalStatePath
    }

    func readPetFramesTopLeft(preferLiveOverlay: Bool = false, liveReference: CGRect? = nil) -> PetFramesTopLeft? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = number(bounds["x"]),
              let y = number(bounds["y"]),
              let overlayWidth = number(bounds["width"]),
              let overlayHeight = number(bounds["height"]),
              let mascotPayload = bounds["mascot"] as? [String: Any],
              let left = number(mascotPayload["left"]),
              let top = number(mascotPayload["top"]),
              let width = number(mascotPayload["width"]),
              let height = number(mascotPayload["height"]) else {
            return nil
        }

        let displayId = directDisplayId(bounds["displayId"])
        let persistedOverlay = CGRect(x: x, y: y, width: overlayWidth, height: overlayHeight)
        let liveOverlay = preferLiveOverlay ? liveCodexOverlayBounds(matching: liveReference ?? persistedOverlay, expectedSize: persistedOverlay.size) : nil
        let overlay = liveOverlay ?? persistedOverlay
        let mascot = CGRect(x: overlay.minX + left, y: overlay.minY + top, width: width, height: height)
        return PetFramesTopLeft(
            mascot: mascot,
            overlay: overlay,
            displayId: liveOverlay == nil ? displayId : nil,
            usedLiveOverlay: liveOverlay != nil
        )
    }

    private func isAvatarOverlayOpen(_ root: [String: Any]) -> Bool {
        if let isOpen = root["electron-avatar-overlay-open"] as? Bool {
            return isOpen
        }
        if let isOpen = root["electron-avatar-overlay-open"] as? NSNumber {
            return isOpen.boolValue
        }
        return true
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }

    private func directDisplayId(_ value: Any?) -> CGDirectDisplayID? {
        if let value = value as? NSNumber {
            return CGDirectDisplayID(value.uint32Value)
        }
        if let value = value as? Int, value >= 0 {
            return CGDirectDisplayID(value)
        }
        if let value = value as? String, let intValue = UInt32(value) {
            return CGDirectDisplayID(intValue)
        }
        return nil
    }

    private func liveCodexOverlayBounds(matching reference: CGRect, expectedSize: CGSize) -> CGRect? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { window -> CGRect? in
            let maxWidthDelta = max(80.0, expectedSize.width * 0.55)
            let maxHeightDelta = max(80.0, expectedSize.height * 0.55)
            guard (window[kCGWindowOwnerName as String] as? String) == "Codex",
                  let layer = number(window[kCGWindowLayer as String]),
                  layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]),
                  width >= 40.0,
                  height >= 40.0,
                  abs(width - expectedSize.width) <= maxWidthDelta,
                  abs(height - expectedSize.height) <= maxHeightDelta else {
                return nil
            }

            return CGRect(x: x, y: y, width: width, height: height)
        }
        .min {
            liveOverlayScore($0, reference: reference, expectedSize: expectedSize) < liveOverlayScore($1, reference: reference, expectedSize: expectedSize)
        }
    }

    private func liveOverlayScore(_ rect: CGRect, reference: CGRect, expectedSize: CGSize) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let distanceScore = distanceSquaredFromCenter(center, to: reference)
        let widthDelta = rect.width - expectedSize.width
        let heightDelta = rect.height - expectedSize.height
        return distanceScore + (widthDelta * widthDelta + heightDelta * heightDelta) * 8.0
    }

}

struct LimitRingRenderer {
    var state: LimitState
    var phase: Double
    var style: RingStyle = .segmentedPixel
    var showsReadout: Bool = false

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clear(rect)

        switch style {
        case .segmentedPixel:
            context.setShouldAntialias(false)
            drawSegmented(in: rect, context: context)
        case .classicGlow:
            context.setShouldAntialias(true)
            drawGlow(in: rect, context: context, isCRT: false)
        case .crtGlow:
            context.setShouldAntialias(true)
            drawGlow(in: rect, context: context, isCRT: true)
        }

        context.restoreGState()
    }

    private func drawSegmented(in rect: CGRect, context: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minSide = min(rect.width, rect.height)
        let urgency = max(urgency(for: state.primary), urgency(for: state.secondary))
        let breathe = CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5)
        let pulse = CGFloat(1.0 + urgency * 0.025 * breathe)
        let outerRadius = (minSide * 0.5 - 16.0) * pulse
        let innerRadius = outerRadius - 13.0

        drawHalo(context, center: center, radius: outerRadius, urgency: CGFloat(urgency), breathe: breathe)
        drawTicks(context, center: center, radius: outerRadius + 5.0)

        if let primary = state.primary {
            let color = limitRingColor(forRemaining: primary.remainingPercent, role: .primary)
            drawRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: 7.0,
                bucket: primary,
                color: color,
                trackAlpha: 0.20,
                phase: phase
            )
        } else {
            drawMissingRing(context, center: center, radius: outerRadius, lineWidth: 7.0)
        }

        if let secondary = state.secondary {
            let color = limitRingColor(forRemaining: secondary.remainingPercent, role: .secondary)
            drawRing(
                context,
                center: center,
                radius: innerRadius,
                lineWidth: 4.5,
                bucket: secondary,
                color: color,
                trackAlpha: 0.14,
                phase: phase + 0.18
            )
        }

        drawModelLimitDots(context, center: center, radius: outerRadius + 11.0, state: state)
        if showsReadout {
            drawLimitReadouts(context, center: center, outerRadius: outerRadius, innerRadius: innerRadius, bounds: rect)
        }
    }

    private struct LimitReadout {
        var text: String
        var detailText: String?
        var ringPoint: CGPoint
        var labelRect: CGRect
        var color: NSColor
        var angle: CGFloat
    }

    private static let readoutPercentAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92)
    ]

    private static let readoutDetailAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.64),
        .kern: -0.35
    ]

    private func urgency(for bucket: LimitBucket?) -> Double {
        guard let bucket else { return 0.0 }
        return min(max((45.0 - bucket.remainingPercent) / 45.0, 0.0), 1.0)
    }

    private func drawGlow(in rect: CGRect, context: CGContext, isCRT: Bool) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minSide = min(rect.width, rect.height)
        let urgency = max(urgency(for: state.primary), urgency(for: state.secondary))
        let breathe = CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5)
        let pulse = CGFloat(1.0 + urgency * 0.02 * breathe)
        let outerRadius = (minSide * 0.5 - 17.0) * pulse
        let innerRadius = outerRadius - 13.5

        drawGlowHalo(context, center: center, radius: outerRadius, urgency: CGFloat(urgency), isCRT: isCRT)
        if isCRT {
            drawCRTPixels(context, center: center, radius: outerRadius + 13.0)
        } else {
            drawStaticGlowPixels(context, center: center, radius: outerRadius + 13.0, color: limitRingColor(forRemaining: 80.0, role: .primary), count: 34, alpha: 0.20)
        }

        drawSmoothTrack(context, center: center, radius: outerRadius, lineWidth: isCRT ? 7.4 : 8.0, alpha: isCRT ? 0.28 : 0.24)
        drawSmoothTrack(context, center: center, radius: innerRadius, lineWidth: isCRT ? 5.0 : 4.8, alpha: isCRT ? 0.20 : 0.16)

        if let primary = state.primary {
            let color = limitRingColor(forRemaining: primary.remainingPercent, role: .primary)
            drawSmoothRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: isCRT ? 7.4 : 8.0,
                bucket: primary,
                color: color,
                glowBoost: isCRT ? 1.28 : 1.0
            )
        } else {
            drawSmoothMissingRing(context, center: center, radius: outerRadius, lineWidth: isCRT ? 7.4 : 8.0)
        }

        if let secondary = state.secondary {
            let color = limitRingColor(forRemaining: secondary.remainingPercent, role: .secondary)
            drawSmoothRing(
                context,
                center: center,
                radius: innerRadius,
                lineWidth: isCRT ? 5.0 : 4.8,
                bucket: secondary,
                color: color,
                glowBoost: isCRT ? 1.18 : 0.92
            )
        }

        drawModelLimitDots(context, center: center, radius: outerRadius + 11.0, state: state)
        if showsReadout {
            drawLimitReadouts(context, center: center, outerRadius: outerRadius, innerRadius: innerRadius, bounds: rect)
        }
    }

    private func drawGlowHalo(_ context: CGContext, center: CGPoint, radius: CGFloat, urgency: CGFloat, isCRT: Bool) {
        context.saveGState()
        let color = NSColor(calibratedRed: 0.22 + urgency * 0.32, green: 0.86 - urgency * 0.16, blue: 0.78 - urgency * 0.32, alpha: 1.0)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: isCRT ? 16.0 : 12.0, color: color.withAlphaComponent(isCRT ? 0.26 : 0.18).cgColor)
        context.setStrokeColor(color.withAlphaComponent(isCRT ? 0.18 : 0.13).cgColor)
        context.setLineWidth(isCRT ? 15.0 : 10.0)
        context.addArc(center: center, radius: radius + 2.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: isCRT ? 0.045 : 0.032).cgColor)
        context.setLineWidth(1.0)
        context.addArc(center: center, radius: radius + 12.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSmoothTrack(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
        context.saveGState()
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.30).cgColor)
        context.setLineWidth(lineWidth + 5.0)
        context.addArc(center: center, radius: radius + 0.5, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: alpha).cgColor)
        context.setLineWidth(lineWidth)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSmoothRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor,
        glowBoost: CGFloat
    ) {
        let start = -CGFloat.pi / 2.0
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        let end = start + max(remaining, 0.018) * CGFloat.pi * 2.0

        context.saveGState()
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 10.0 * glowBoost, color: color.withAlphaComponent(0.42).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.24).cgColor)
        context.setLineWidth(lineWidth + 7.0)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 4.0 * glowBoost, color: color.withAlphaComponent(0.52).cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.26).cgColor)
        context.setLineWidth(max(1.4, lineWidth * 0.22))
        context.addArc(center: center, radius: radius - lineWidth * 0.22, startAngle: start + 0.02, endAngle: end - 0.02, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSmoothMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
        context.setLineWidth(lineWidth)
        context.addArc(center: center, radius: radius, startAngle: -CGFloat.pi / 2.0, endAngle: CGFloat.pi * 1.24, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawStaticGlowPixels(_ context: CGContext, center: CGPoint, radius: CGFloat, color: NSColor, count: Int, alpha: CGFloat) {
        context.saveGState()
        context.setShouldAntialias(false)
        for i in 0..<count {
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / CGFloat(count) * CGFloat.pi * 2.0
            let wobble = CGFloat((i * 37) % 13 - 6)
            let dot = polarPoint(center: center, radius: radius + wobble, angle: angle)
            let size: CGFloat = i % 9 == 0 ? 3.0 : 2.0
            let rect = CGRect(x: dot.x - size / 2.0, y: dot.y - size / 2.0, width: size, height: size).integral
            context.setFillColor(color.withAlphaComponent(alpha * (i % 9 == 0 ? 1.2 : 0.75)).cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }

    private func drawCRTPixels(_ context: CGContext, center: CGPoint, radius: CGFloat) {
        context.saveGState()
        context.setShouldAntialias(false)
        let green = NSColor(calibratedRed: 0.31, green: 1.0, blue: 0.82, alpha: 0.18)
        let blue = NSColor(calibratedRed: 0.52, green: 0.86, blue: 1.0, alpha: 0.14)
        for i in 0..<48 {
            guard i % 3 == 0 || i % 13 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 48.0 * CGFloat.pi * 2.0
            let dot = polarPoint(center: center, radius: radius + CGFloat(i % 3) * 2.0, angle: angle)
            let size: CGFloat = i % 13 == 0 ? 3.0 : 2.0
            context.setFillColor((i % 4 == 0 ? green : blue).cgColor)
            context.fill(CGRect(x: dot.x - size / 2.0, y: dot.y - size / 2.0, width: size, height: size).integral)
        }
        context.restoreGState()
    }

    private func drawHalo(_ context: CGContext, center: CGPoint, radius: CGFloat, urgency: CGFloat, breathe: CGFloat) {
        context.saveGState()
        let color = NSColor(calibratedRed: 0.18 + urgency * 0.35, green: 0.82 - urgency * 0.18, blue: 0.78 - urgency * 0.36, alpha: 0.10 + urgency * 0.08)
        for i in 0..<48 {
            guard i % 4 == 0 || i % 11 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 48.0 * CGFloat.pi * 2.0
            let point = polarPoint(center: center, radius: radius + 12.0 + (i % 4 == 0 ? 2.0 : 0.0), angle: angle)
            let size: CGFloat = i % 8 == 0 ? 2.5 : 1.8
            let rect = CGRect(x: point.x - size / 2.0, y: point.y - size / 2.0, width: size, height: size).integral
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }

    private func drawTicks(_ context: CGContext, center: CGPoint, radius: CGFloat) {
        context.saveGState()
        for i in 0..<24 {
            guard i % 2 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 24.0 * CGFloat.pi * 2.0
            let tick = polarPoint(center: center, radius: radius + (i % 6 == 0 ? 0.5 : 0.0), angle: angle)
            let size: CGFloat = i % 6 == 0 ? 3.5 : 2.5
            let rect = CGRect(x: tick.x - size / 2.0, y: tick.y - size / 2.0, width: size, height: size)
            context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: i % 6 == 0 ? 0.16 : 0.10).cgColor)
            context.fill(rect.integral)
        }
        context.restoreGState()
    }

    private func drawRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor,
        trackAlpha: CGFloat,
        phase: Double
    ) {
        let start = -CGFloat.pi / 2.0
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        let segmentCount = lineWidth >= 7.0 ? 72 : 56
        let filledSegments = max(Int(ceil(remaining * CGFloat(segmentCount))), remaining > 0 ? 1 : 0)
        let tangential = max(3.0, (radius * CGFloat.pi * 2.0 / CGFloat(segmentCount)) * 0.55)

        context.saveGState()
        for index in 0..<segmentCount {
            let angle = start + (CGFloat(index) + 0.5) / CGFloat(segmentCount) * CGFloat.pi * 2.0
            let isFilled = index < filledSegments
            drawPixelRingCell(
                context,
                center: center,
                radius: radius,
                angle: angle,
                tangential: tangential,
                radial: lineWidth,
                color: isFilled ? color : NSColor(calibratedWhite: 1.0, alpha: trackAlpha),
                backingAlpha: isFilled ? 0.48 : 0.28
            )
        }
        context.restoreGState()
    }

    private func drawPixelRingCell(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        angle: CGFloat,
        tangential: CGFloat,
        radial: CGFloat,
        color: NSColor,
        backingAlpha: CGFloat
    ) {
        let position = polarPoint(center: center, radius: radius, angle: angle)
        context.saveGState()
        context.translateBy(x: position.x, y: position.y)
        context.rotate(by: angle + CGFloat.pi / 2.0)

        let backing = CGRect(x: -tangential / 2.0 - 1.0, y: -radial / 2.0 - 1.0, width: tangential + 2.0, height: radial + 2.0).integral
        context.setFillColor(NSColor(calibratedWhite: 0.02, alpha: backingAlpha).cgColor)
        context.fill(backing)

        let rect = CGRect(x: -tangential / 2.0, y: -radial / 2.0, width: tangential, height: radial).integral
        context.setFillColor(color.cgColor)
        context.fill(rect)

        context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1.0))
        context.restoreGState()
    }

    private func drawMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        for i in 0..<44 {
            guard i % 4 != 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 44.0 * CGFloat.pi * 1.74
            drawPixelRingCell(
                context,
                center: center,
                radius: radius,
                angle: angle,
                tangential: 3.0,
                radial: lineWidth,
                color: NSColor(calibratedWhite: 1.0, alpha: 0.16),
                backingAlpha: 0.22
            )
        }
        context.restoreGState()
    }

    private func drawLimitReadouts(_ context: CGContext, center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, bounds: CGRect) {
        var readouts: [LimitReadout] = []
        if let primary = state.primary {
            readouts.append(makeReadout(
                text: formatUsagePercent(primary.remainingPercent),
                detailText: formatResetCountdown(primary.resetAt),
                center: center,
                ringRadius: outerRadius,
                labelRadius: outerRadius + 22.0,
                remainingPercent: primary.remainingPercent,
                color: limitRingColor(forRemaining: primary.remainingPercent, role: .primary),
                bounds: bounds
            ))
        }

        if let secondary = state.secondary {
            readouts.append(makeReadout(
                text: formatUsagePercent(secondary.remainingPercent),
                detailText: formatResetCountdown(secondary.resetAt),
                center: center,
                ringRadius: innerRadius,
                labelRadius: innerRadius + 21.0,
                remainingPercent: secondary.remainingPercent,
                color: limitRingColor(forRemaining: secondary.remainingPercent, role: .secondary),
                bounds: bounds
            ))
        }

        for readout in resolveReadoutOverlaps(readouts, bounds: bounds) {
            drawReadout(context, readout: readout)
        }
    }

    private func makeReadout(
        text: String,
        detailText: String?,
        center: CGPoint,
        ringRadius: CGFloat,
        labelRadius: CGFloat,
        remainingPercent: Double,
        color: NSColor,
        bounds: CGRect
    ) -> LimitReadout {
        let angle = -CGFloat.pi / 2.0 + CGFloat(max(remainingPercent, 1.8) / 100.0) * CGFloat.pi * 2.0
        let ringPoint = polarPoint(center: center, radius: ringRadius, angle: angle)
        let labelPoint = polarPoint(center: center, radius: labelRadius, angle: angle)
        let percentSize = NSAttributedString(string: text, attributes: Self.readoutPercentAttributes).size()
        let detailSize = detailText.map { NSAttributedString(string: $0, attributes: Self.readoutDetailAttributes).size() } ?? .zero
        let labelSize = CGSize(
            width: ceil(max(text.count > 3 ? 45.0 : 38.0, percentSize.width + 20.0, detailSize.width + 18.0)),
            height: detailText == nil ? 22.0 : 34.0
        )
        var labelRect = CGRect(
            x: labelPoint.x - labelSize.width / 2,
            y: labelPoint.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        labelRect = clamp(labelRect, inside: bounds)
        return LimitReadout(text: text, detailText: detailText, ringPoint: ringPoint, labelRect: labelRect, color: color, angle: angle)
    }

    private func resolveReadoutOverlaps(_ readouts: [LimitReadout], bounds: CGRect) -> [LimitReadout] {
        guard readouts.count > 1 else { return readouts }
        var resolved = readouts

        let averageAngle = resolved.map(\.angle).reduce(0, +) / CGFloat(resolved.count)
        let tangent = CGPoint(x: -sin(averageAngle), y: cos(averageAngle))
        for index in resolved.indices {
            let direction = index == 0 ? -1.0 : 1.0
            resolved[index].labelRect = clamp(resolved[index].labelRect.offsetBy(dx: tangent.x * 12.0 * direction, dy: tangent.y * 12.0 * direction), inside: bounds)
        }

        for _ in 0..<8 {
            var changed = false
            for firstIndex in 0..<resolved.count {
                for secondIndex in (firstIndex + 1)..<resolved.count {
                    let first = expanded(resolved[firstIndex].labelRect)
                    let second = expanded(resolved[secondIndex].labelRect)
                    guard first.intersects(second) else { continue }

                    let xOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
                    let yOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                    let gap: CGFloat = 6.0
                    if xOverlap <= yOverlap {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midX <= resolved[secondIndex].labelRect.midX ? -1.0 : 1.0
                        let nudge = xOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: direction * nudge, dy: 0)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: -direction * nudge, dy: 0)
                    } else {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midY <= resolved[secondIndex].labelRect.midY ? -1.0 : 1.0
                        let nudge = yOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: 0, dy: direction * nudge)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: 0, dy: -direction * nudge)
                    }

                    resolved[firstIndex].labelRect = clamp(resolved[firstIndex].labelRect, inside: bounds)
                    resolved[secondIndex].labelRect = clamp(resolved[secondIndex].labelRect, inside: bounds)
                    changed = true
                }
            }
            if !changed { break }
        }

        return resolved
    }

    private func expanded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -4.0, dy: -3.0)
    }

    private func clamp(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var clamped = rect
        let inset = bounds.insetBy(dx: 4, dy: 4)
        clamped.origin.x = min(max(clamped.minX, inset.minX), inset.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, inset.minY), inset.maxY - clamped.height)
        return clamped
    }

    private func drawReadout(_ context: CGContext, readout: LimitReadout) {
        context.saveGState()
        context.setLineCap(.butt)
        context.setStrokeColor(readout.color.withAlphaComponent(0.58).cgColor)
        context.setLineWidth(1.0)
        context.move(to: readout.ringPoint)
        context.addLine(to: CGPoint(x: readout.labelRect.midX, y: readout.labelRect.midY))
        context.strokePath()

        let rect = readout.labelRect.integral
        context.setFillColor(NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.13, alpha: 0.84).cgColor)
        context.fill(rect)
        context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor)
        context.fill(CGRect(x: rect.minX + 1.0, y: rect.maxY - 3.0, width: rect.width - 2.0, height: 2.0))
        context.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.72).cgColor)
        context.setLineWidth(1.0)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        context.setStrokeColor(readout.color.withAlphaComponent(0.70).cgColor)
        context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        let percent = NSAttributedString(string: readout.text, attributes: Self.readoutPercentAttributes)
        let percentSize = percent.size()

        if let detailText = readout.detailText {
            let detail = NSAttributedString(string: detailText, attributes: Self.readoutDetailAttributes)
            let detailSize = detail.size()
            let totalHeight = percentSize.height + detailSize.height - 1.0
            let detailY = readout.labelRect.midY - totalHeight / 2.0 - 0.5
            let percentY = detailY + detailSize.height - 1.0
            percent.draw(at: CGPoint(x: readout.labelRect.midX - percentSize.width / 2.0, y: percentY))
            detail.draw(at: CGPoint(x: readout.labelRect.midX - detailSize.width / 2.0, y: detailY))
        } else {
            percent.draw(at: CGPoint(x: readout.labelRect.midX - percentSize.width / 2, y: readout.labelRect.midY - percentSize.height / 2 + 0.5))
        }
        context.restoreGState()
    }

    private func drawModelLimitDots(_ context: CGContext, center: CGPoint, radius: CGFloat, state: LimitState) {
        let dots = Array(state.additional.prefix(8))
        let dotCount = dots.count
        guard dotCount > 0 else { return }
        let angleStep = CGFloat.pi * 2.0 / CGFloat(dotCount)

        context.saveGState()
        for (index, item) in dots.enumerated() {
            let angle = -CGFloat.pi / 2.0 + CGFloat(index) * angleStep
            let dot = polarPoint(center: center, radius: radius, angle: angle)
            let color = limitRingColor(forRemaining: item.bucket.remainingPercent, role: .primary)
            let rect = CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5.0, height: 5.0).integral
            context.setFillColor(NSColor(calibratedWhite: 0.0, alpha: 0.55).cgColor)
            context.fill(rect.insetBy(dx: -1.0, dy: -1.0))
            context.setFillColor(color.withAlphaComponent(0.82).cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }

    private func formatResetCountdown(_ resetAt: TimeInterval?) -> String? {
        guard var resetAt else { return nil }
        if resetAt > 10_000_000_000 {
            resetAt /= 1000.0
        }

        let seconds = max(0, resetAt - Date().timeIntervalSince1970)
        if seconds <= 0 {
            return "soon"
        }
        if seconds < 60 {
            return "<1m"
        }
        if seconds >= 2.0 * 24.0 * 60.0 * 60.0 {
            return "\(Int(ceil(seconds / (24.0 * 60.0 * 60.0))))d"
        }

        let minutes = Int(ceil(seconds / 60.0))
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            if hours >= 6 || remainingMinutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(remainingMinutes)m"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        if days >= 7 || remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
    }

}

final class LimitRingView: NSView {
    var style: RingStyle = .segmentedPixel {
        didSet {
            if style != oldValue {
                lastOrbitBounds = .null
                needsDisplay = true
                updateOrbitStyle()
                updateOrbitPathsIfNeeded()
                updateDynamicDust()
                updateOrbitVisibility()
            }
        }
    }
    var state: LimitState = .empty {
        didSet {
            if !state.isVisuallyEquivalent(to: oldValue) {
                needsDisplay = true
                updateOrbitStyle()
            }
            updateDynamicDust()
        }
    }
    var phase: Double = 0 {
        didSet {
            if abs(phase - oldValue) > 0.0001 {
                needsDisplay = true
            }
        }
    }
    var showsReadout: Bool = false {
        didSet {
            if showsReadout != oldValue {
                needsDisplay = true
            }
        }
    }
    var orbitsEnabled: Bool = true {
        didSet {
            if orbitsEnabled != oldValue {
                updateOrbitVisibility()
            }
        }
    }
    var pixelCloudEnabled: Bool = true {
        didSet {
            if pixelCloudEnabled != oldValue {
                updateDynamicDust()
                updateOrbitVisibility()
            }
        }
    }

    private let orbitContainerLayer = CALayer()
    private let outerOrbitLayer = CALayer()
    private let innerOrbitLayer = CALayer()
    private let dustContainerLayer = CALayer()
    private let outerDustAuraEmitter = CAEmitterLayer()
    private var lastOrbitBounds: CGRect = .null
    private var lastDustConfiguration: DustConfiguration?
    private static let dustPixelContents = LimitRingView.makeDustPixelContents()

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupOrbitLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupOrbitLayers()
    }

    override func layout() {
        super.layout()
        updateOrbitPathsIfNeeded()
        updateDynamicDust()
    }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(
            state: state,
            phase: phase,
            style: style,
            showsReadout: showsReadout
        ).draw(in: bounds)
    }

    private func setupOrbitLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        dustContainerLayer.zPosition = 950
        dustContainerLayer.masksToBounds = false
        layer?.addSublayer(dustContainerLayer)
        configureDustEmitter(outerDustAuraEmitter)
        dustContainerLayer.addSublayer(outerDustAuraEmitter)

        orbitContainerLayer.zPosition = 1000
        orbitContainerLayer.masksToBounds = false
        layer?.addSublayer(orbitContainerLayer)

        configureOrbitDot(outerOrbitLayer, size: 7.0)
        configureOrbitDot(innerOrbitLayer, size: 5.0)
        orbitContainerLayer.addSublayer(outerOrbitLayer)
        orbitContainerLayer.addSublayer(innerOrbitLayer)
        updateOrbitStyle()
        updateOrbitVisibility()
    }

    private func configureOrbitDot(_ dot: CALayer, size: CGFloat) {
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = 1.0
        dot.borderWidth = 1.0
        dot.borderColor = NSColor(calibratedWhite: 0.04, alpha: 0.58).cgColor
        dot.shadowOpacity = 0.34
        dot.shadowRadius = 2.0
        dot.shadowOffset = .zero
        dot.zPosition = 1001
        dot.contentsScale = 1.0
        dot.magnificationFilter = .nearest
        dot.minificationFilter = .nearest
        dot.actions = [
            "position": NSNull(),
            "opacity": NSNull(),
            "backgroundColor": NSNull()
        ]
    }

    private func configureDustEmitter(_ emitter: CAEmitterLayer) {
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.renderMode = .unordered
        emitter.masksToBounds = false
        emitter.birthRate = 0.0
        emitter.seed = 2_654_435_761
        emitter.zPosition = 951
        emitter.actions = [
            "emitterPosition": NSNull(),
            "emitterSize": NSNull(),
            "birthRate": NSNull(),
            "opacity": NSNull()
        ]
    }

    private func updateOrbitPathsIfNeeded() {
        guard bounds.width > 0, bounds.height > 0, !bounds.equalTo(lastOrbitBounds) else { return }
        lastOrbitBounds = bounds
        orbitContainerLayer.frame = bounds

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let minSide = min(bounds.width, bounds.height)
        let baseOuterRadius = minSide * 0.5 - 16.0
        let baseInnerRadius = max(baseOuterRadius - 13.0, 1.0)
        let outerRadius = max(baseOuterRadius + style.outerOrbitOffset, 1.0)
        let innerRadius = max(baseInnerRadius + style.innerOrbitOffset, 1.0)

        installOrbitAnimation(
            on: outerOrbitLayer,
            center: center,
            radius: outerRadius,
            duration: style.outerOrbitDuration,
            clockwise: false,
            timeOffset: 0.0
        )
        installOrbitAnimation(
            on: innerOrbitLayer,
            center: center,
            radius: innerRadius,
            duration: style.innerOrbitDuration,
            clockwise: true,
            timeOffset: 0.0
        )
    }

    private func installOrbitAnimation(on dot: CALayer, center: CGPoint, radius: CGFloat, duration: CFTimeInterval, clockwise: Bool, timeOffset: CFTimeInterval) {
        dot.position = CGPoint(x: center.x, y: center.y - radius)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: -CGFloat.pi / 2.0,
            endAngle: clockwise ? -CGFloat.pi / 2.0 - CGFloat.pi * 2.0 : -CGFloat.pi / 2.0 + CGFloat.pi * 2.0,
            clockwise: clockwise
        )

        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.calculationMode = .paced
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.rotationMode = nil
        animation.isRemovedOnCompletion = false
        animation.timeOffset = timeOffset
        dot.add(animation, forKey: "orbit")
    }

    private func updateOrbitStyle() {
        let outerColor = state.primary.map { limitRingColor(forRemaining: $0.remainingPercent, role: .primary) }
            ?? NSColor(calibratedWhite: 1.0, alpha: 0.78)
        let innerColor = state.secondary.map { limitRingColor(forRemaining: $0.remainingPercent, role: .secondary) }
            ?? NSColor(calibratedWhite: 1.0, alpha: 0.52)

        switch style {
        case .segmentedPixel:
            applyOrbitDotStyle(
                outerOrbitLayer,
                size: 5.0,
                color: outerColor,
                alpha: 0.82,
                cornerRadius: 1.0,
                borderAlpha: 0.66,
                shadowOpacity: 0.16,
                shadowRadius: 1.0
            )
            applyOrbitDotStyle(
                innerOrbitLayer,
                size: 5.5,
                color: innerColor,
                alpha: 0.88,
                cornerRadius: 1.0,
                borderAlpha: 0.70,
                shadowOpacity: 0.24,
                shadowRadius: 1.4
            )
        case .classicGlow:
            applyOrbitDotStyle(
                outerOrbitLayer,
                size: 6.0,
                color: outerColor,
                alpha: 0.86,
                cornerRadius: 1.0,
                borderAlpha: 0.46,
                shadowOpacity: 0.34,
                shadowRadius: 3.0
            )
            applyOrbitDotStyle(
                innerOrbitLayer,
                size: 5.6,
                color: innerColor,
                alpha: 0.90,
                cornerRadius: 1.0,
                borderAlpha: 0.50,
                shadowOpacity: 0.34,
                shadowRadius: 2.6
            )
        case .crtGlow:
            applyOrbitDotStyle(
                outerOrbitLayer,
                size: 4.0,
                color: outerColor,
                alpha: 0.76,
                cornerRadius: 0.0,
                borderAlpha: 0.40,
                shadowOpacity: 0.26,
                shadowRadius: 2.0
            )
            applyOrbitDotStyle(
                innerOrbitLayer,
                size: 4.2,
                color: innerColor,
                alpha: 0.82,
                cornerRadius: 0.0,
                borderAlpha: 0.44,
                shadowOpacity: 0.24,
                shadowRadius: 1.8
            )
        }
    }

    private func applyOrbitDotStyle(
        _ dot: CALayer,
        size: CGFloat,
        color: NSColor,
        alpha: CGFloat,
        cornerRadius: CGFloat,
        borderAlpha: CGFloat,
        shadowOpacity: Float,
        shadowRadius: CGFloat
    ) {
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = cornerRadius
        dot.borderWidth = 1.0
        dot.borderColor = NSColor(calibratedWhite: 0.02, alpha: borderAlpha).cgColor
        dot.backgroundColor = color.withAlphaComponent(alpha).cgColor
        dot.shadowColor = color.withAlphaComponent(0.72).cgColor
        dot.shadowOpacity = shadowOpacity
        dot.shadowRadius = shadowRadius
    }

    private func updateDynamicDust() {
        guard bounds.width > 0, bounds.height > 0 else {
            dustContainerLayer.opacity = 0.0
            stopDustEmitters()
            return
        }

        dustContainerLayer.frame = bounds
        let visible = pixelCloudEnabled
        guard visible, let primary = state.primary, primary.remainingPercent > 2.5 else {
            stopDustEmitters()
            return
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let minSide = min(bounds.width, bounds.height)
        let outerRingRadius = minSide * 0.5 - style.dustFieldRingInset
        let emitterRadius = max(outerRingRadius + style.dustFieldRadiusOutset, 1.0)
        let color = limitRingColor(forRemaining: primary.remainingPercent, role: .primary)
        let colorBand = dustColorBand(for: primary.remainingPercent)
        let configuration = DustConfiguration(bounds: bounds, style: style, colorBand: colorBand)
        guard configuration != lastDustConfiguration else { return }
        lastDustConfiguration = configuration

        outerDustAuraEmitter.isHidden = false
        outerDustAuraEmitter.frame = bounds
        outerDustAuraEmitter.emitterPosition = center
        outerDustAuraEmitter.emitterSize = CGSize(width: emitterRadius * 2.0, height: emitterRadius * 2.0)
        outerDustAuraEmitter.emitterCells = [
            makeDustCell(color: color, role: .near),
            makeDustCell(color: color, role: .wander)
        ]
        outerDustAuraEmitter.birthRate = 1.0
    }

    private func stopDustEmitters() {
        lastDustConfiguration = nil
        outerDustAuraEmitter.birthRate = 0.0
        outerDustAuraEmitter.isHidden = true
    }

    private enum DustCellRole {
        case near
        case wander
    }

    private func makeDustCell(color: NSColor, role: DustCellRole) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Self.dustPixelContents
        let lifetime: Float
        let scale: CGFloat
        switch role {
        case .near:
            let alpha = style.dustFieldAlpha
            cell.color = color.withAlphaComponent(alpha).cgColor
            cell.birthRate = style.dustFieldBirthRate
            lifetime = style.dustFieldLifetime
            cell.velocity = style.dustFieldVelocity
            cell.velocityRange = style.dustFieldVelocity * 0.9
            scale = style.dustFieldScale
            cell.alphaSpeed = -Float(alpha) / max(lifetime, 0.1)
        case .wander:
            let alpha = style.dustFieldAlpha * 0.46
            cell.color = color.withAlphaComponent(alpha).cgColor
            cell.birthRate = style.dustFieldBirthRate * 0.22
            lifetime = style.dustFieldLifetime * 1.25
            cell.velocity = style.dustFieldVelocity * 2.3
            cell.velocityRange = style.dustFieldVelocity * 1.25
            scale = style.dustFieldScale * 0.82
            cell.alphaSpeed = -Float(alpha) / max(lifetime, 0.1)
        }
        cell.lifetime = lifetime
        cell.lifetimeRange = lifetime * 0.18
        cell.emissionLongitude = 0.0
        cell.emissionRange = CGFloat.pi * 2.0
        cell.scale = scale
        cell.scaleRange = scale * 0.42
        cell.scaleSpeed = -scale / CGFloat(max(lifetime, 0.1)) * 0.12
        return cell
    }

    private static func makeDustPixelContents() -> CGImage? {
        let size = NSSize(width: 3.0, height: 3.0)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private struct DustConfiguration: Equatable {
        var bounds: CGRect
        var style: RingStyle
        var colorBand: DustColorBand
    }

    private enum DustColorBand: Equatable {
        case healthy
        case low
        case critical
    }

    private func dustColorBand(for remaining: Double) -> DustColorBand {
        if remaining <= 12 {
            return .critical
        }
        if remaining <= 30 {
            return .low
        }
        return .healthy
    }

    private func updateOrbitVisibility() {
        let orbitOpacity: Float = orbitsEnabled && style.usesOrbitHighlights ? 1.0 : 0.0
        orbitContainerLayer.opacity = orbitOpacity
        orbitContainerLayer.speed = orbitOpacity > 0.0 ? 1.0 : 0.0

        let dustOpacity: Float = pixelCloudEnabled ? 1.0 : 0.0
        dustContainerLayer.opacity = dustOpacity
        dustContainerLayer.speed = dustOpacity > 0.0 ? 1.0 : 0.0
        updateDynamicDust()
    }

}

final class LimitRingsApp: NSObject {
    private struct CodexOverlayWindowMatch {
        var number: Int
        var layer: Int
    }

    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
    private var pixelCloudItem: NSMenuItem?
    private var orbitGlintsItem: NSMenuItem?
    private var ringStyleItems: [NSMenuItem] = []
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var dragFollowTimer: Timer?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var globalStateSource: DispatchSourceFileSystemObject?
    private var pendingGlobalStateWatcherRestart: DispatchWorkItem?
    private var pendingFrameUpdate: DispatchWorkItem?
    private var currentPetFrameAppKit: CGRect?
    private var currentPetOverlayTopLeft: CGRect?
    private var currentPetOverlayFrameAppKit: CGRect?
    private var currentPetOverlayWindowNumber: Int?
    private var currentPetOverlayWindowLayer: Int?
    private var currentPetDisplayId: CGDirectDisplayID?
    private var lastPanelFrame: CGRect?
    private var lastPanelOrderWindowNumber: Int?
    private var lastOverlayWindowMatchRefreshAt: Date?
    private var lastGoodState: LimitState?
    private var isTrackingMouseDrag = false
    private var dragMouseToPetOriginOffsetAppKit: CGPoint?
    private var dragMouseToOverlayOriginOffsetAppKit: CGPoint?
    private var holdDraggedFrameUntil: Date?
    private var ringsVisible: Bool
    private var pixelCloudEnabled: Bool
    private var orbitGlintsEnabled: Bool
    private var ringStyle: RingStyle
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath)
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.pixelCloudEnabled = UserDefaults.standard.object(forKey: pixelCloudEnabledDefaultsKey) as? Bool ?? true
        self.orbitGlintsEnabled = UserDefaults.standard.object(forKey: orbitGlintsEnabledDefaultsKey) as? Bool ?? true
        self.ringStyle = UserDefaults.standard.string(forKey: ringStyleDefaultsKey)
            .flatMap(RingStyle.init(rawValue:)) ?? config.ringStyle
        self.panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        ringView.style = ringStyle
        panel.contentView = ringView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = fallbackPanelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()
    }

    deinit {
        stateTimer?.invalidate()
        frameTimer?.invalidate()
        dragFollowTimer?.invalidate()
        pendingGlobalStateWatcherRestart?.cancel()
        pendingFrameUpdate?.cancel()
        globalStateSource?.cancel()
        [mouseDownMonitor, mouseDragMonitor, mouseUpMonitor, mouseMoveMonitor].compactMap { $0 }.forEach {
            NSEvent.removeMonitor($0)
        }
    }

    func run() {
        installStatusMenu()
        updateState()
        updateFrame()
        installGlobalStateWatcher()
        updateRingVisibility()

        stateTimer = Timer.scheduledTimer(withTimeInterval: limitStatePollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFrameFallbackPollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        installDragFollow()
        updateOrbitAnimationState()
    }

    private func updateState() {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            DispatchQueue.main.async {
                if state.hasLimitData {
                    self.lastGoodState = state
                    self.ringView.state = state
                } else if var lastGoodState = self.lastGoodState {
                    lastGoodState.source = "last-\(lastGoodState.source)"
                    self.ringView.state = lastGoodState
                } else {
                    self.ringView.state = state
                }
                self.updateSummaryMenuItem()
                self.updateStatusBarIcon()
                self.stateReadInFlight = false
            }
        }
    }

    private func installGlobalStateWatcher() {
        pendingGlobalStateWatcherRestart?.cancel()
        pendingGlobalStateWatcherRestart = nil
        globalStateSource?.cancel()
        globalStateSource = nil

        let descriptor = open(config.globalStatePath.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleGlobalStateWatcherRestart(after: 1.0)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.globalStateSource?.data ?? []
            self.scheduleFrameUpdateFromGlobalState()
            if events.contains(.delete) || events.contains(.rename) {
                self.scheduleGlobalStateWatcherRestart(after: 0.2)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        globalStateSource = source
        source.resume()
    }

    private func scheduleGlobalStateWatcherRestart(after delay: TimeInterval) {
        pendingGlobalStateWatcherRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGlobalStateWatcherRestart = nil
            self.installGlobalStateWatcher()
            self.scheduleFrameUpdateFromGlobalState()
        }
        pendingGlobalStateWatcherRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFrameUpdateFromGlobalState() {
        pendingFrameUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFrameUpdate = nil
            self.updateFrame()
            self.updateTooltip(at: NSEvent.mouseLocation)
        }
        pendingFrameUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + petFrameStateDebounceInterval, execute: work)
    }

    private func updateFrame(preferLiveOverlay: Bool = false) {
        if let holdDraggedFrameUntil, Date() < holdDraggedFrameUntil {
            return
        }
        holdDraggedFrameUntil = nil
        if isTrackingMouseDrag && !preferLiveOverlay {
            return
        }

        let liveReference = preferLiveOverlay ? currentPetOverlayTopLeft : nil
        guard let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: preferLiveOverlay, liveReference: liveReference) else {
            currentPetFrameAppKit = nil
            currentPetOverlayTopLeft = nil
            currentPetOverlayFrameAppKit = nil
            currentPetOverlayWindowNumber = nil
            currentPetOverlayWindowLayer = nil
            currentPetDisplayId = nil
            isTrackingMouseDrag = false
            dragMouseToPetOriginOffsetAppKit = nil
            dragMouseToOverlayOriginOffsetAppKit = nil
            stopDragFollowTimer()
            ringView.showsReadout = false
            updateOrbitAnimationState()
            hidePanel()
            return
        }

        if preferLiveOverlay,
           isTrackingMouseDrag,
           !petFrames.usedLiveOverlay,
           currentPetFrameAppKit != nil {
            return
        }

        applyPetFrames(petFrames)
    }

    private func applyPetFrames(_ petFrames: PetFramesTopLeft) {
        let nextPetFrameAppKit = appKitRectFromTopLeft(petFrames.mascot, displayId: petFrames.displayId)
        let nextOverlayFrameAppKit = appKitRectFromTopLeft(petFrames.overlay, displayId: petFrames.displayId)
        let petFrameChanged = currentPetFrameAppKit.map { !framesAreClose($0, nextPetFrameAppKit) } ?? true
        let overlayFrameChanged = currentPetOverlayFrameAppKit.map { !framesAreClose($0, nextOverlayFrameAppKit) } ?? true
        let displayChanged = currentPetDisplayId != petFrames.displayId

        currentPetFrameAppKit = nextPetFrameAppKit
        currentPetOverlayTopLeft = petFrames.overlay
        currentPetOverlayFrameAppKit = nextOverlayFrameAppKit
        currentPetDisplayId = petFrames.displayId

        if overlayWindowMatchNeedsRefresh(overlayFrameChanged: overlayFrameChanged, displayChanged: displayChanged) {
            refreshCurrentPetOverlayWindowNumber()
        }
        if petFrameChanged || displayChanged || lastPanelFrame == nil {
            setPanelFrame(forPetFrameTopLeft: petFrames.mascot, displayId: petFrames.displayId)
        }
        if ringsVisible, !panel.isVisible || overlayFrameChanged || displayChanged || lastPanelOrderWindowNumber != currentPetOverlayWindowNumber {
            showPanel()
        }
        let shouldEnableOrbitGlints = ringsVisible && orbitGlintsEnabled && currentPetFrameAppKit != nil && ringStyle.usesOrbitHighlights
        let shouldEnablePixelCloud = ringsVisible && pixelCloudEnabled && currentPetFrameAppKit != nil
        if petFrameChanged || displayChanged || ringView.orbitsEnabled != shouldEnableOrbitGlints || ringView.pixelCloudEnabled != shouldEnablePixelCloud {
            updateOrbitAnimationState()
        }
    }

    private func setPanelFrame(forPetFrameTopLeft petFrame: CGRect, displayId: CGDirectDisplayID?) {
        let padding: CGFloat = 38
        let size = max(petFrame.width, petFrame.height) + padding * 2
        let center = visualRingCenter(for: petFrame)
        let topLeft = CGPoint(x: center.x - size / 2, y: center.y - size / 2)
        let origin = appKitOriginFromTopLeft(topLeft, size: CGSize(width: size, height: size), displayId: displayId)

        applyPanelFrame(CGRect(origin: origin, size: CGSize(width: size, height: size)))
    }

    private func setPanelFrame(forPetFrameAppKit petFrame: CGRect) {
        let padding: CGFloat = 38
        let size = max(petFrame.width, petFrame.height) + padding * 2
        let center = visualRingCenter(forAppKitPetFrame: petFrame)
        let origin = CGPoint(x: center.x - size / 2, y: center.y - size / 2)
        applyPanelFrame(CGRect(origin: origin, size: CGSize(width: size, height: size)))
    }

    private func visualRingCenter(for petFrameTopLeft: CGRect) -> CGPoint {
        CGPoint(
            x: petFrameTopLeft.midX,
            y: petFrameTopLeft.midY + petFrameTopLeft.height * petVisualCenterYOffsetFraction
        )
    }

    private func visualRingCenter(forAppKitPetFrame petFrame: CGRect) -> CGPoint {
        CGPoint(
            x: petFrame.midX,
            y: petFrame.midY - petFrame.height * petVisualCenterYOffsetFraction
        )
    }

    private func applyPanelFrame(_ frame: CGRect) {
        if let lastPanelFrame, framesAreClose(lastPanelFrame, frame) {
            return
        }
        lastPanelFrame = frame
        panel.setFrame(frame, display: true)
    }

    private func framesAreClose(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= panelFrameUpdateTolerance &&
            abs(first.minY - second.minY) <= panelFrameUpdateTolerance &&
            abs(first.width - second.width) <= panelFrameUpdateTolerance &&
            abs(first.height - second.height) <= panelFrameUpdateTolerance
    }

    private func showPanel() {
        updatePanelLevel()
        if panel.isVisible, lastPanelOrderWindowNumber == currentPetOverlayWindowNumber {
            return
        }
        if let currentPetOverlayWindowNumber {
            panel.order(.below, relativeTo: currentPetOverlayWindowNumber)
        } else {
            panel.orderFrontRegardless()
        }
        lastPanelOrderWindowNumber = currentPetOverlayWindowNumber
    }

    private func hidePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
        lastPanelOrderWindowNumber = nil
    }

    private func updateOrbitAnimationState() {
        ringView.orbitsEnabled = ringsVisible && orbitGlintsEnabled && currentPetFrameAppKit != nil && ringStyle.usesOrbitHighlights
        ringView.pixelCloudEnabled = ringsVisible && pixelCloudEnabled && currentPetFrameAppKit != nil
    }

    private func refreshCurrentPetOverlayWindowNumber() {
        lastOverlayWindowMatchRefreshAt = Date()
        guard let overlayFrame = currentPetOverlayFrameAppKit,
              let reference = globalTopLeftRectFromAppKit(overlayFrame) else {
            currentPetOverlayWindowNumber = nil
            currentPetOverlayWindowLayer = nil
            return
        }
        if let match = codexOverlayWindowMatch(matching: reference, expectedSize: overlayFrame.size) {
            currentPetOverlayWindowNumber = match.number
            currentPetOverlayWindowLayer = match.layer
        } else {
            currentPetOverlayWindowNumber = nil
            currentPetOverlayWindowLayer = nil
        }
    }

    private func overlayWindowMatchNeedsRefresh(overlayFrameChanged: Bool, displayChanged: Bool) -> Bool {
        guard !overlayFrameChanged, !displayChanged, currentPetOverlayWindowNumber != nil else {
            return true
        }
        guard let lastOverlayWindowMatchRefreshAt else {
            return true
        }
        return Date().timeIntervalSince(lastOverlayWindowMatchRefreshAt) >= overlayWindowMatchRefreshInterval
    }

    private func updatePanelLevel() {
        let targetLevel = currentPetOverlayWindowLayer
            .map { NSWindow.Level(rawValue: $0) }
            ?? fallbackPanelLevel
        if panel.level.rawValue != targetLevel.rawValue {
            panel.level = targetLevel
        }
    }

    private func codexOverlayWindowMatch(matching reference: CGRect, expectedSize: CGSize) -> CodexOverlayWindowMatch? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { window -> (match: CodexOverlayWindowMatch, score: CGFloat)? in
            let maxWidthDelta = max(80.0, expectedSize.width * 0.55)
            let maxHeightDelta = max(80.0, expectedSize.height * 0.55)
            guard (window[kCGWindowOwnerName as String] as? String) == "Codex",
                  let layer = cgInt(window[kCGWindowLayer as String]),
                  layer > 0,
                  let windowNumber = cgInt(window[kCGWindowNumber as String]),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = cgNumber(bounds["X"]),
                  let y = cgNumber(bounds["Y"]),
                  let width = cgNumber(bounds["Width"]),
                  let height = cgNumber(bounds["Height"]),
                  width >= 40.0,
                  height >= 40.0,
                  abs(width - expectedSize.width) <= maxWidthDelta,
                  abs(height - expectedSize.height) <= maxHeightDelta else {
                return nil
            }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            return (
                CodexOverlayWindowMatch(number: windowNumber, layer: layer),
                overlayWindowScore(rect, reference: reference, expectedSize: expectedSize)
            )
        }
        .min { $0.score < $1.score }?
        .match
    }

    private func overlayWindowScore(_ rect: CGRect, reference: CGRect, expectedSize: CGSize) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let distanceScore = distanceSquared(center, to: reference)
        let widthDelta = rect.width - expectedSize.width
        let heightDelta = rect.height - expectedSize.height
        return distanceScore + (widthDelta * widthDelta + heightDelta * heightDelta) * 8.0
    }

    private func cgNumber(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }

    private func cgInt(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Rings", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let cloudItem = NSMenuItem(title: "Pixel Cloud", action: #selector(togglePixelCloud(_:)), keyEquivalent: "")
        cloudItem.target = self
        menu.addItem(cloudItem)
        pixelCloudItem = cloudItem

        let glintsItem = NSMenuItem(title: "Orbiting Glints", action: #selector(toggleOrbitGlints(_:)), keyEquivalent: "")
        glintsItem.target = self
        menu.addItem(glintsItem)
        orbitGlintsItem = glintsItem

        let styleRoot = NSMenuItem(title: "Ring Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        ringStyleItems = RingStyle.allCases.map { style in
            let item = NSMenuItem(title: style.menuTitle, action: #selector(selectRingStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            styleMenu.addItem(item)
            return item
        }
        menu.addItem(styleRoot)
        menu.setSubmenu(styleMenu, for: styleRoot)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let debugItem = NSMenuItem(title: "Copy Debug Geometry", action: #selector(copyDebugGeometry(_:)), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateStatusBarIcon()
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateDecorationMenuItems()
        updateRingStyleMenuItems()
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        button.image = makeStatusBarIcon(for: ringView.state)
        button.toolTip = statusBarTooltip(for: ringView.state)
    }

    private func makeStatusBarIcon(for state: LimitState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: 9.0, y: 9.0)
        drawStatusTrack(center: center, radius: 6.8, lineWidth: 2.2, alpha: 0.28)
        drawStatusTrack(center: center, radius: 3.8, lineWidth: 1.7, alpha: 0.20)

        if let primary = state.primary {
            drawStatusArc(
                center: center,
                radius: 6.8,
                lineWidth: 2.2,
                remaining: primary.remainingPercent,
                color: statusColor(forRemaining: primary.remainingPercent, role: .primary)
            )
        } else {
            drawStatusMissingArc(center: center, radius: 6.8, lineWidth: 2.2)
        }

        if let secondary = state.secondary {
            drawStatusArc(
                center: center,
                radius: 3.8,
                lineWidth: 1.7,
                remaining: secondary.remainingPercent,
                color: statusColor(forRemaining: secondary.remainingPercent, role: .secondary)
            )
        }

        NSColor(calibratedWhite: 1.0, alpha: 0.30).setFill()
        NSBezierPath(rect: CGRect(x: 8.35, y: 8.35, width: 1.3, height: 1.3)).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func drawStatusTrack(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: 270, clockwise: false)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        NSColor(calibratedWhite: 1.0, alpha: alpha).setStroke()
        path.stroke()
    }

    private func drawStatusArc(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, remaining: Double, color: NSColor) {
        let sweep = max(min(remaining, 100.0), 0.0) / 100.0 * 360.0
        guard sweep > 0.5 else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawStatusMissingArc(center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -210, clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        NSColor(calibratedWhite: 1.0, alpha: 0.58).setStroke()
        path.stroke()
    }

    private enum StatusRingRole {
        case primary
        case secondary
    }

    private func statusColor(forRemaining remaining: Double, role: StatusRingRole) -> NSColor {
        if remaining <= 12 {
            return NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.26, alpha: 0.96)
        }
        if remaining <= 30 {
            return NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.24, alpha: 0.96)
        }
        if role == .secondary {
            return NSColor(calibratedRed: 0.38, green: 0.72, blue: 1.00, alpha: 0.94)
        }
        return NSColor(calibratedRed: 0.28, green: 0.95, blue: 0.76, alpha: 0.96)
    }

    private func statusBarTooltip(for state: LimitState) -> String {
        let primary = state.primary.map { "Short \(formatUsagePercent($0.remainingPercent))" }
        let secondary = state.secondary.map { "Weekly \(formatUsagePercent($0.remainingPercent))" }
        let pieces = [primary, secondary].compactMap { $0 }
        guard !pieces.isEmpty else {
            return "Codex usage: waiting for limit data"
        }
        let source = state.source == "live" ? "Live" : state.source.hasPrefix("last-") ? "Last" : "Cached"
        return "Codex usage (\(source)): " + pieces.joined(separator: " | ")
    }

    private func updateSummaryMenuItem() {
        guard let summaryItem else { return }
        let primary = ringView.state.primary.map { "Short \(formatUsagePercent($0.remainingPercent))" }
        let secondary = ringView.state.secondary.map { "Weekly \(formatUsagePercent($0.remainingPercent))" }
        let pieces = [primary, secondary].compactMap { $0 }
        if pieces.isEmpty {
            summaryItem.title = "Waiting for Codex limit data"
        } else {
            let source: String
            if ringView.state.source.hasPrefix("last-") {
                source = "Last"
            } else {
                source = ringView.state.source == "live" ? "Live" : "Cached"
            }
            summaryItem.title = "\(source) " + pieces.joined(separator: " | ")
        }
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateDecorationMenuItems() {
        pixelCloudItem?.state = pixelCloudEnabled ? .on : .off
        orbitGlintsItem?.state = orbitGlintsEnabled ? .on : .off
    }

    private func updateRingStyleMenuItems() {
        for item in ringStyleItems {
            let itemStyle = (item.representedObject as? String).flatMap(RingStyle.init(rawValue:))
            item.state = itemStyle == ringStyle ? .on : .off
        }
    }

    private func updateRingVisibility() {
        updateShowRingsMenuItem()
        if ringsVisible, currentPetFrameAppKit != nil {
            showPanel()
            updateTooltip(at: NSEvent.mouseLocation)
        } else {
            ringView.showsReadout = false
            hidePanel()
        }
        updateOrbitAnimationState()
    }

    private func setRingsVisible(_ visible: Bool) {
        ringsVisible = visible
        UserDefaults.standard.set(visible, forKey: ringsVisibleDefaultsKey)
        updateRingVisibility()
    }

    private func setPixelCloudEnabled(_ enabled: Bool) {
        pixelCloudEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: pixelCloudEnabledDefaultsKey)
        updateDecorationMenuItems()
        updateOrbitAnimationState()
    }

    private func setOrbitGlintsEnabled(_ enabled: Bool) {
        orbitGlintsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: orbitGlintsEnabledDefaultsKey)
        updateDecorationMenuItems()
        updateOrbitAnimationState()
    }

    private func setRingStyle(_ style: RingStyle) {
        guard ringStyle != style else { return }
        ringStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: ringStyleDefaultsKey)
        ringView.style = style
        updateRingStyleMenuItems()
        updateOrbitAnimationState()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func togglePixelCloud(_ sender: NSMenuItem) {
        setPixelCloudEnabled(!pixelCloudEnabled)
    }

    @objc private func toggleOrbitGlints(_ sender: NSMenuItem) {
        setOrbitGlintsEnabled(!orbitGlintsEnabled)
    }

    @objc private func selectRingStyle(_ sender: NSMenuItem) {
        guard let rawStyle = sender.representedObject as? String,
              let style = RingStyle(rawValue: rawStyle) else {
            return
        }
        setRingStyle(style)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func copyDebugGeometry(_ sender: NSMenuItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(debugGeometryReport(), forType: .string)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func installDragFollow() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.beginDragFollowIfNeeded(at: NSEvent.mouseLocation)
            }
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.continueDragFollow(at: NSEvent.mouseLocation)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endDragFollow()
            }
        }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTooltip(at: NSEvent.mouseLocation)
            }
        }
    }

    private func beginDragFollowIfNeeded(at mouse: CGPoint) {
        guard ringsVisible else { return }
        updateFrame()
        guard isLikelyPetDragStart(at: mouse) else { return }
        guard let petFrame = currentPetFrameAppKit,
              let overlayFrame = currentPetOverlayFrameAppKit else { return }
        dragMouseToPetOriginOffsetAppKit = CGPoint(x: petFrame.minX - mouse.x, y: petFrame.minY - mouse.y)
        dragMouseToOverlayOriginOffsetAppKit = CGPoint(x: overlayFrame.minX - mouse.x, y: overlayFrame.minY - mouse.y)
        isTrackingMouseDrag = true
        holdDraggedFrameUntil = nil
        startDragFollowTimer()
        updateDragFrame(at: mouse)
        ringView.showsReadout = false
    }

    private func continueDragFollow(at mouse: CGPoint) {
        if !isTrackingMouseDrag {
            beginDragFollowIfNeeded(at: mouse)
        }
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }
        updateDragFrame(at: mouse)
        ringView.showsReadout = false
    }

    private func endDragFollow() {
        guard isTrackingMouseDrag else { return }
        isTrackingMouseDrag = false
        dragMouseToPetOriginOffsetAppKit = nil
        dragMouseToOverlayOriginOffsetAppKit = nil
        stopDragFollowTimer()
        holdDraggedFrameUntil = Date().addingTimeInterval(0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.updateFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateFrame()
        }
    }

    private func isPrimaryMouseButtonPressed() -> Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    private func updateDragFrame(at mouse: CGPoint) {
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }

        let predictedPetFrame = predictedDragPetFrame(at: mouse)
        let predictedOverlayFrame = predictedDragOverlayFrame(at: mouse)
        let liveReference = predictedOverlayFrame.flatMap { globalTopLeftRectFromAppKit($0) }
            ?? currentPetOverlayFrameAppKit.flatMap { globalTopLeftRectFromAppKit($0) }
            ?? currentPetOverlayTopLeft

        if let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: true, liveReference: liveReference),
           petFrames.usedLiveOverlay {
            let livePetFrame = appKitRectFromTopLeft(petFrames.mascot, displayId: petFrames.displayId)
            if let predictedPetFrame {
                guard dragLiveFrameIsClose(livePetFrame, to: predictedPetFrame) else {
                    applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
                    ringView.showsReadout = false
                    return
                }
            }
            applyPetFrames(petFrames)
            ringView.showsReadout = false
            return
        }

        if let predictedPetFrame {
            applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
        }
        ringView.showsReadout = false
    }

    private func predictedDragPetFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetFrameAppKit,
              let offset = dragMouseToPetOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetFrameAppKit.width,
            height: currentPetFrameAppKit.height
        )
    }

    private func predictedDragOverlayFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetOverlayFrameAppKit,
              let offset = dragMouseToOverlayOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetOverlayFrameAppKit.width,
            height: currentPetOverlayFrameAppKit.height
        )
    }

    private func applyPredictedDragFrame(petFrame: CGRect, overlayFrame: CGRect?) {
        currentPetFrameAppKit = petFrame
        if let overlayFrame {
            currentPetOverlayFrameAppKit = overlayFrame
            currentPetOverlayTopLeft = topLeftRectFromAppKit(overlayFrame, displayId: currentPetDisplayId)
            refreshCurrentPetOverlayWindowNumber()
        }
        setPanelFrame(forPetFrameAppKit: petFrame)
        if ringsVisible {
            showPanel()
        }
        updateOrbitAnimationState()
    }

    private func dragLiveFrameIsClose(_ liveFrame: CGRect, to predictedFrame: CGRect) -> Bool {
        let dx = liveFrame.midX - predictedFrame.midX
        let dy = liveFrame.midY - predictedFrame.midY
        let tolerance = max(dragLiveMismatchTolerance, max(predictedFrame.width, predictedFrame.height) * 0.85)
        return (dx * dx + dy * dy) <= tolerance * tolerance
    }

    private func startDragFollowTimer() {
        guard dragFollowTimer == nil else { return }
        let timer = Timer(timeInterval: dragFollowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isTrackingMouseDrag, self.isPrimaryMouseButtonPressed() else {
                self.endDragFollow()
                return
            }
            self.updateDragFrame(at: NSEvent.mouseLocation)
        }
        dragFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDragFollowTimer() {
        dragFollowTimer?.invalidate()
        dragFollowTimer = nil
    }

    private func isLikelyPetDragStart(at mouse: CGPoint) -> Bool {
        if isPetControlHotspot(at: mouse) {
            return false
        }
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -14, dy: -14).contains(mouse) {
            return true
        }
        return false
    }

    private func isPetControlHotspot(at mouse: CGPoint) -> Bool {
        guard let petFrame = currentPetFrameAppKit else { return false }
        let controlSize: CGFloat = 52.0
        let lowerRight = CGRect(
            x: petFrame.maxX - controlSize * 0.55,
            y: petFrame.minY - controlSize * 0.45,
            width: controlSize,
            height: controlSize
        )
        let upperRight = CGRect(
            x: petFrame.maxX - controlSize * 0.55,
            y: petFrame.maxY - controlSize * 0.55,
            width: controlSize,
            height: controlSize
        )
        return lowerRight.contains(mouse) || upperRight.contains(mouse)
    }

    private func updateTooltip(at mouse: CGPoint) {
        if !ringsVisible || currentPetFrameAppKit == nil || isTrackingMouseDrag || isPetControlHotspot(at: mouse) {
            ringView.showsReadout = false
            return
        }

        ringView.showsReadout = isHoveringRingOrPet(mouse)
    }

    private func isHoveringRingOrPet(_ mouse: CGPoint) -> Bool {
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -10, dy: -10).contains(mouse) {
            return true
        }

        let frame = panel.frame
        guard frame.insetBy(dx: -4, dy: -4).contains(mouse) else {
            return false
        }

        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let distance = hypot(local.x - center.x, local.y - center.y)
        let radius = min(frame.width, frame.height) * 0.5 - 16.0
        return distance >= radius - 24.0 && distance <= radius + 19.0
    }

    private func appKitOriginFromTopLeft(_ topLeft: CGPoint, size: CGSize, displayId: CGDirectDisplayID?) -> CGPoint {
        let topLeftRect = CGRect(origin: topLeft, size: size)
        guard let screen = screenForTopLeftRect(topLeftRect, displayId: displayId) else {
            return CGPoint(x: topLeft.x, y: max(0, config.fallbackSize - topLeft.y))
        }

        let screenTopLeftFrame = coordinateTopLeftFrame(for: screen, displayId: displayId)
        let localX = topLeft.x - screenTopLeftFrame.minX
        let localY = topLeft.y - screenTopLeftFrame.minY
        return CGPoint(x: screen.frame.minX + localX, y: screen.frame.maxY - localY - size.height)
    }

    private func appKitRectFromTopLeft(_ rect: CGRect, displayId: CGDirectDisplayID?) -> CGRect {
        guard let screen = screenForTopLeftRect(rect, displayId: displayId) else {
            return rect
        }

        let screenTopLeftFrame = coordinateTopLeftFrame(for: screen, displayId: displayId)
        let localX = rect.minX - screenTopLeftFrame.minX
        let localY = rect.minY - screenTopLeftFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func topLeftRectFromAppKit(_ rect: CGRect, displayId: CGDirectDisplayID?) -> CGRect? {
        guard let screen = screenForAppKitRect(rect, displayId: displayId) else {
            return nil
        }

        let screenTopLeftFrame = coordinateTopLeftFrame(for: screen, displayId: displayId)
        let localX = rect.minX - screen.frame.minX
        let localY = screen.frame.maxY - rect.maxY
        return CGRect(
            x: screenTopLeftFrame.minX + localX,
            y: screenTopLeftFrame.minY + localY,
            width: rect.width,
            height: rect.height
        )
    }

    private func globalTopLeftRectFromAppKit(_ rect: CGRect) -> CGRect? {
        topLeftRectFromAppKit(rect, displayId: nil)
    }

    private func screenForTopLeftRect(_ rect: CGRect, displayId: CGDirectDisplayID?) -> NSScreen? {
        if let displayId, let screen = screenForDisplayId(displayId) {
            return screen
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { topLeftFrame(for: $0).contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: topLeftFrame(for: $0)) < distanceSquared(center, to: topLeftFrame(for: $1))
        }
    }

    private func screenForAppKitRect(_ rect: CGRect, displayId: CGDirectDisplayID?) -> NSScreen? {
        if let displayId, let screen = screenForDisplayId(displayId) {
            return screen
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: $0.frame) < distanceSquared(center, to: $1.frame)
        }
    }

    private func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = (primaryScreen() ?? NSScreen.screens.first)?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func coordinateTopLeftFrame(for screen: NSScreen, displayId: CGDirectDisplayID?) -> CGRect {
        if displayId != nil {
            return CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        }
        return topLeftFrame(for: screen)
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
    }

    private func screenForDisplayId(_ displayId: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayId
        }
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func debugGeometryReport() -> String {
        let displayId = currentPetDisplayId.map(String.init) ?? "global"
        let screen = currentPetFrameAppKit.flatMap { screenForAppKitRect($0, displayId: currentPetDisplayId) }
        var lines = [
            "Codex Pet Limit Rings Debug Geometry",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
            "statePath: \(config.globalStatePath.path)",
            "limitSource: \(ringView.state.source)",
            "ringsVisible: \(ringsVisible)",
            "ringStyle: \(ringStyle.rawValue)",
            "pixelCloudEnabled: \(pixelCloudEnabled)",
            "orbitGlintsEnabled: \(orbitGlintsEnabled)",
            "panelVisible: \(panel.isVisible)",
            "trackingDrag: \(isTrackingMouseDrag)",
            "displayId: \(displayId)",
            "overlayWindowNumber: \(currentPetOverlayWindowNumber.map(String.init) ?? "none")",
            "overlayWindowLayer: \(currentPetOverlayWindowLayer.map(String.init) ?? "none")",
            "panelLevel: \(panel.level.rawValue)",
            "fallbackPanelLevel: \(fallbackPanelLevel.rawValue)",
            "screen: \(screen.map(screenDebugDescription) ?? "none")",
            "petFrameAppKit: \(formatRect(currentPetFrameAppKit))",
            "overlayFrameAppKit: \(formatRect(currentPetOverlayFrameAppKit))",
            "overlayTopLeft: \(formatRect(currentPetOverlayTopLeft))",
            "panelFrame: \(formatRect(panel.frame))",
            "lastPanelFrame: \(formatRect(lastPanelFrame))",
            "orbitsEnabled: \(ringView.orbitsEnabled)",
            "viewPixelCloudEnabled: \(ringView.pixelCloudEnabled)"
        ]

        for (index, screen) in NSScreen.screens.enumerated() {
            lines.append("screen[\(index)]: \(screenDebugDescription(screen))")
        }
        return lines.joined(separator: "\n")
    }

    private func screenDebugDescription(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
        return "id=\(number) frame=\(formatRect(screen.frame)) visible=\(formatRect(screen.visibleFrame))"
    }

    private func formatRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "{x: %.1f, y: %.1f, w: %.1f, h: %.1f}",
            rect.minX,
            rect.minY,
            rect.width,
            rect.height
        )
    }

}

func renderPreview(config: LimitRingsConfig) -> Bool {
    let state = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let width = Int(size.width.rounded(.up))
    let height = Int(size.height.rounded(.up))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return false
    }

    context.clear(CGRect(origin: .zero, size: size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    LimitRingRenderer(state: state, phase: 0.18, style: config.ringStyle, showsReadout: true).draw(in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let previewPath = config.previewPath,
          let cgImage = context.makeImage() else {
        return false
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try FileManager.default.createDirectory(at: previewPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: previewPath)
        return true
    } catch {
        fputs("codex-pet-limit-rings: could not write preview: \(error)\n", stderr)
        return false
    }
}

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        authPath: codexHome.appendingPathComponent("auth.json"),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--style STYLE] [--codex-home PATH] [--logs PATH] [--auth PATH] [--state PATH]

            Draws a transparent Codex rate-limit rings around the current pet.
            Styles: \(RingStyle.allCases.map(\.rawValue).joined(separator: ", "))
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
            config.authPath = url.appendingPathComponent("auth.json")
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
        case "--auth":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.authPath = URL(fileURLWithPath: value)
        case "--state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.globalStatePath = URL(fileURLWithPath: value)
        case "--size":
            guard let value = args.first, let size = Double(value) else { return nil }
            args.removeFirst()
            config.fallbackSize = CGFloat(size)
        case "--style":
            guard let value = args.first,
                  let style = RingStyle(rawValue: value) else {
                fputs("codex-pet-limit-rings: invalid style. Use one of: \(RingStyle.allCases.map(\.rawValue).joined(separator: ", "))\n", stderr)
                return nil
            }
            args.removeFirst()
            config.ringStyle = style
        default:
            fputs("codex-pet-limit-rings: unknown argument \(arg)\n", stderr)
            return nil
        }
    }

    return config
}

func defaultLogsPath(codexHome: URL) -> URL {
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

guard let config = parseConfig() else {
    fputs("codex-pet-limit-rings: invalid arguments. Use --help.\n", stderr)
    exit(2)
}

if config.previewPath != nil {
    exit(renderPreview(config: config) ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rings = LimitRingsApp(config: config)
rings.run()
app.run()
