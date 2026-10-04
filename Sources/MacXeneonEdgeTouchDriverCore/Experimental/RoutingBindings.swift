import Foundation

/// Read-only observations supplied by a future IOKit adapter. A controller ID
/// may be filled only after identifying the appropriate USB device ancestor;
/// an arbitrary common parent, location ID, or serial is not that evidence.
public struct ExperimentalEndpointObservation: Equatable, Sendable {
    public let source: ExperimentalSourceEpoch
    public let registryEntryID: UInt64?
    public let controllerRegistryEntryID: UInt64?
    public let vendorID: UInt32
    public let productID: UInt32

    public init(source: ExperimentalSourceEpoch, registryEntryID: UInt64?, controllerRegistryEntryID: UInt64?, vendorID: UInt32, productID: UInt32) {
        self.source = source
        self.registryEntryID = registryEntryID
        self.controllerRegistryEntryID = controllerRegistryEntryID
        self.vendorID = vendorID
        self.productID = productID
    }
}

public struct ExperimentalDisplayGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
        width > 0 && height > 0 && (x + width).isFinite && (y + height).isFinite &&
        x < x + width && y < y + height
    }
}

public struct ExperimentalDisplayObservation: Equatable, Sendable {
    public let displayID: UInt32
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32
    public let geometry: ExperimentalDisplayGeometry
    public let isActive: Bool
    public let isMirrored: Bool

    public init(displayID: UInt32, vendorNumber: UInt32, modelNumber: UInt32, serialNumber: UInt32, geometry: ExperimentalDisplayGeometry, isActive: Bool = true, isMirrored: Bool = false) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.geometry = geometry
        self.isActive = isActive
        self.isMirrored = isMirrored
    }
}

/// First-trial selectors are exact, boot-scoped runtime identities. Hardware
/// serial and port fallback are intentionally absent from this version.
public struct ExperimentalEndpointSelector: Equatable, Sendable {
    public let registryEntryID: UInt64
    public let vendorID: UInt32
    public let productID: UInt32
    public let controllerRegistryEntryID: UInt64?

    public init(registryEntryID: UInt64, vendorID: UInt32, productID: UInt32, controllerRegistryEntryID: UInt64? = nil) {
        self.registryEntryID = registryEntryID
        self.vendorID = vendorID
        self.productID = productID
        self.controllerRegistryEntryID = controllerRegistryEntryID
    }
}

public struct ExperimentalDisplaySelector: Equatable, Sendable {
    public let displayID: UInt32
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32?

    public init(displayID: UInt32, vendorNumber: UInt32, modelNumber: UInt32, serialNumber: UInt32? = nil) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }
}

public struct ExperimentalExplicitBinding: Equatable, Sendable {
    public let id: String
    public let bootSessionID: String
    public let endpoint: ExperimentalEndpointSelector
    public let display: ExperimentalDisplaySelector

    public init(id: String, bootSessionID: String, endpoint: ExperimentalEndpointSelector, display: ExperimentalDisplaySelector) {
        self.id = id
        self.bootSessionID = bootSessionID
        self.endpoint = endpoint
        self.display = display
    }
}

public struct ExperimentalResolvedBinding: Equatable, Sendable {
    public let source: ExperimentalSourceEpoch
    public let route: ExperimentalRouteToken
    public let controllerRegistryEntryID: UInt64?
    public let geometry: ExperimentalDisplayGeometry
}

public struct ExperimentalBindingFailure: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case emptyBindings, invalidSelector, duplicateBindingID
        case bootSessionUnavailable, bootSessionMismatch
        case endpointMissing, endpointAmbiguous, endpointIdentityMismatch
        case displayMissing, displayAmbiguous, displayIdentityMismatch, displayUnavailable
        case duplicateSource, duplicateDisplay, controllerProvenanceRequired, duplicateController
    }
    public let bindingID: String?
    public let reason: Reason
}

public enum ExperimentalBindingResolution: Equatable, Sendable {
    case resolved([ExperimentalResolvedBinding])
    case blocked([ExperimentalBindingFailure])
}

/// Pure whole-configuration validation. Any failure blocks the entire explicit
/// routing set. Enumeration order is never used to break identity ambiguity.
public enum ExperimentalBindingValidator {
    public static func resolve(
        _ bindings: [ExperimentalExplicitBinding],
        currentBootSessionID: String?,
        endpoints: [ExperimentalEndpointObservation],
        displays: [ExperimentalDisplayObservation],
        bindingRevision: UInt64,
        topologyRevision: UInt64
    ) -> ExperimentalBindingResolution {
        guard !bindings.isEmpty else {
            return .blocked([ExperimentalBindingFailure(bindingID: nil, reason: .emptyBindings)])
        }
        guard let boot = currentBootSessionID, !boot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .blocked([ExperimentalBindingFailure(bindingID: nil, reason: .bootSessionUnavailable)])
        }
        var failures: [ExperimentalBindingFailure] = []
        var resolved: [ExperimentalResolvedBinding] = []
        var bindingIDs: Set<String> = []
        var selectedSources: Set<ExperimentalSourceEpoch> = []
        var selectedDisplays: Set<UInt32> = []
        var selectedControllers: Set<UInt64> = []

        for binding in bindings {
            func fail(_ reason: ExperimentalBindingFailure.Reason) {
                failures.append(ExperimentalBindingFailure(bindingID: binding.id, reason: reason))
            }
            guard !binding.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  binding.endpoint.registryEntryID != 0, binding.display.displayID != 0 else {
                fail(.invalidSelector); continue
            }
            guard bindingIDs.insert(binding.id).inserted else { fail(.duplicateBindingID); continue }
            guard binding.bootSessionID == boot else { fail(.bootSessionMismatch); continue }
            let sources = endpoints.filter { $0.registryEntryID == binding.endpoint.registryEntryID }
            guard !sources.isEmpty else { fail(.endpointMissing); continue }
            guard sources.count == 1 else { fail(.endpointAmbiguous); continue }
            let source = sources[0]
            guard source.vendorID == binding.endpoint.vendorID,
                  source.productID == binding.endpoint.productID,
                  binding.endpoint.controllerRegistryEntryID.map({ source.controllerRegistryEntryID == $0 }) ?? true else {
                fail(.endpointIdentityMismatch); continue
            }
            let targets = displays.filter { $0.displayID == binding.display.displayID }
            guard !targets.isEmpty else { fail(.displayMissing); continue }
            guard targets.count == 1 else { fail(.displayAmbiguous); continue }
            let target = targets[0]
            guard target.vendorNumber == binding.display.vendorNumber,
                  target.modelNumber == binding.display.modelNumber,
                  binding.display.serialNumber.map({ target.serialNumber == $0 }) ?? true else {
                fail(.displayIdentityMismatch); continue
            }
            guard target.isActive, !target.isMirrored, target.geometry.isValid else {
                fail(.displayUnavailable); continue
            }
            guard selectedSources.insert(source.source).inserted else { fail(.duplicateSource); continue }
            guard selectedDisplays.insert(target.displayID).inserted else { fail(.duplicateDisplay); continue }
            if bindings.count > 1 {
                guard let controller = source.controllerRegistryEntryID, controller != 0 else {
                    fail(.controllerProvenanceRequired); continue
                }
                guard selectedControllers.insert(controller).inserted else { fail(.duplicateController); continue }
            }
            resolved.append(ExperimentalResolvedBinding(
                source: source.source,
                route: ExperimentalRouteToken(bindingID: binding.id, bindingRevision: bindingRevision, topologyRevision: topologyRevision, displayID: target.displayID),
                controllerRegistryEntryID: source.controllerRegistryEntryID,
                geometry: target.geometry
            ))
        }
        return failures.isEmpty ? .resolved(resolved) : .blocked(failures)
    }
}
