import Foundation
import FoundationModels

/// Which Apple foundation model serves a question.
public enum ModelRoute: String, Sendable, CaseIterable {
    /// On-device system model, general use case.
    case onDevice = "on-device"
    /// On-device system model with the content-tagging adapter.
    case tagging
    /// Apple's server model on Private Cloud Compute.
    case pcc
    /// On-device unless the call would not fit the on-device context window
    /// and Private Cloud Compute is available.
    case auto
}

public struct RouterError: JevMacError {
    public let description: String
}

/// Resolves routes to concrete Apple foundation models (the laya router,
/// minus third-party checkpoints: every route is an Apple model).
public final class Router: Sendable {
    let onDevice = SystemLanguageModel.default
    let tagging = SystemLanguageModel(useCase: .contentTagging)
    let pcc = PrivateCloudComputeLanguageModel()

    public init() {}

    public var pccAvailable: Bool { pcc.isAvailable }

    public func onDeviceAvailability() -> String {
        Router.describe(onDevice.availability)
    }

    public func taggingAvailability() -> String {
        Router.describe(tagging.availability)
    }

    public func pccAvailability() -> String {
        switch pcc.availability {
        case .available: return "available"
        case let .unavailable(reason): return "unavailable (\(reason))"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ a: SystemLanguageModel.Availability) -> String {
        switch a {
        case .available: return "available"
        case .unavailable(.deviceNotEligible): return "unavailable (device not eligible)"
        case .unavailable(.appleIntelligenceNotEnabled): return "unavailable (Apple Intelligence is turned off)"
        case .unavailable(.modelNotReady): return "unavailable (model assets still downloading)"
        case let .unavailable(other): return "unavailable (\(other))"
        @unknown default: return "unknown"
        }
    }

    public var onDeviceContextSize: Int { onDevice.contextSize }

    /// Exact token count of `text` under the on-device model's tokenizer.
    public func tokenCount(_ text: String) async throws -> Int { try await onDevice.tokenCount(for: text) }

    public var onDeviceVariant: String { onDevice.variant.displayName }

    public func supportsLanguage(_ code: String) -> Bool {
        onDevice.supportsLocale(Locale(identifier: code))
    }

    /// The routing rule, kept free of live availability checks so it can be
    /// tested exhaustively. `nil` means the requested route cannot be served.
    public static func choose(_ route: ModelRoute, onDevice: Bool, tagging: Bool, pcc: Bool,
                              contextSize: Int, estimatedTokens: Int) -> ModelRoute? {
        switch route {
        case .onDevice: return onDevice ? .onDevice : nil
        case .tagging: return tagging ? .tagging : nil
        case .pcc: return pcc ? .pcc : nil
        case .auto:
            let fits = estimatedTokens < Int(Double(contextSize) * 0.85)
            if onDevice, fits || !pcc { return .onDevice }
            return pcc ? .pcc : nil
        }
    }

    /// Picks the concrete route for a call of roughly `estimatedTokens` tokens.
    public func resolve(_ route: ModelRoute, estimatedTokens: Int) throws -> ModelRoute {
        if let r = Router.choose(route, onDevice: onDevice.isAvailable, tagging: tagging.isAvailable,
                                 pcc: pcc.isAvailable, contextSize: onDevice.contextSize,
                                 estimatedTokens: estimatedTokens) {
            return r
        }
        switch route {
        case .onDevice: throw RouterError(description: "on-device model " + onDeviceAvailability())
        case .tagging: throw RouterError(description: "content-tagging model " + taggingAvailability())
        case .pcc: throw RouterError(description: "Private Cloud Compute model " + pccAvailability())
        case .auto: throw RouterError(description: "no Apple foundation model available: on-device " + onDeviceAvailability())
        }
    }

    /// A fresh session for a concrete route.
    public func session(for route: ModelRoute, instructions: String) -> LanguageModelSession {
        switch route {
        case .tagging: return LanguageModelSession(model: tagging, instructions: instructions)
        case .pcc: return LanguageModelSession(model: pcc, instructions: instructions)
        case .onDevice, .auto: return LanguageModelSession(model: onDevice, instructions: instructions)
        }
    }

    /// Rough token estimate without a model round trip (~4 chars/token).
    public static func estimateTokens(_ texts: String...) -> Int {
        texts.reduce(0) { $0 + $1.utf8.count / 4 + 1 }
    }
}
