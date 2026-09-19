import ApplicationServices
import Foundation
import Geometry

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}

// Only WindowAccess may read or mutate the wrapped AX element.
final class WindowReference: @unchecked Sendable {
    fileprivate let element: AXUIElement
    fileprivate init(_ element: AXUIElement) { self.element = element }
}

struct WindowSnapshot: Sendable {
    let reference: WindowReference
    let frame: CGRect
    let pid: pid_t
}

struct FrameSample: Sendable {
    let stage: String
    let frame: CGRect
}

struct PlacementResult: Sendable {
    let status: String
    let message: String
    let original: CGRect?
    let expected: CGRect?
    let actual: CGRect?
    let milliseconds: Int
    let samples: [FrameSample]
    var succeeded: Bool { status == "exact" || status == "adjusted" }
}

struct AccessFailure: Error, Sendable {
    let status: String
    let message: String
}

actor WindowAccess {
    private func failure(_ error: AXError) -> AccessFailure {
        let status: String
        switch error {
        case .apiDisabled: status = "denied"
        case .attributeUnsupported, .notImplemented: status = "unsupported"
        default: status = "failed"
        }
        return AccessFailure(status: status, message: "AX error \(error.rawValue)")
    }

    private func prepare(_ element: AXUIElement, until deadline: TimeInterval,
                         cancellation: Cancellation? = nil) throws {
        guard cancellation?.cancelled != true else {
            throw AccessFailure(status: "failed", message: "Операция отменена")
        }
        guard AXIsProcessTrusted() else {
            throw AccessFailure(status: "denied", message: "Нет разрешения Accessibility")
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AccessFailure(status: "failed", message: "Истёк бюджет AX") }
        let error = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
        guard error == .success else { throw failure(error) }
    }

    private func read(_ element: AXUIElement, _ name: String, until deadline: TimeInterval,
                      cancellation: Cancellation? = nil) throws -> CFTypeRef {
        try prepare(element, until: deadline, cancellation: cancellation)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { throw failure(error) }
        return value
    }

    private func element(_ value: CFTypeRef) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AccessFailure(status: "unsupported", message: "Неверный тип AX element")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func frame(_ element: AXUIElement, until deadline: TimeInterval,
                       cancellation: Cancellation? = nil) throws -> CGRect {
        let position = try read(element, kAXPositionAttribute, until: deadline, cancellation: cancellation)
        let size = try read(element, kAXSizeAttribute, until: deadline, cancellation: cancellation)
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw AccessFailure(status: "unsupported", message: "Нет геометрии AX")
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite),
              dimensions.width > 0, dimensions.height > 0 else {
            throw AccessFailure(status: "unsupported", message: "Невалидная геометрия AX")
        }
        return CGRect(origin: point, size: dimensions)
    }

    private func validate(_ window: AXUIElement, until deadline: TimeInterval,
                          cancellation: Cancellation? = nil) throws {
        let role = try read(window, kAXRoleAttribute, until: deadline, cancellation: cancellation) as? String
        let subrole = try read(window, kAXSubroleAttribute, until: deadline, cancellation: cancellation) as? String
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else {
            throw AccessFailure(status: "unsupported", message: "Поддерживаются только обычные окна")
        }
        let minimized = try read(window, kAXMinimizedAttribute, until: deadline, cancellation: cancellation) as? Bool
        guard minimized == false else { throw AccessFailure(status: "unsupported", message: "Окно свёрнуто или статус неизвестен") }
        do {
            let fullScreen = try read(window, "AXFullScreen", until: deadline, cancellation: cancellation) as? Bool
            guard fullScreen == false else { throw AccessFailure(status: "unsupported", message: "Полноэкранное окно или статус неизвестен") }
        } catch let error as AccessFailure {
            // Missing fullscreen metadata is handled conservatively in the prototype.
            throw error
        }
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            try prepare(window, until: deadline, cancellation: cancellation)
            var settable: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(window, attribute as CFString, &settable)
            guard error == .success else { throw failure(error) }
            guard settable.boolValue else { throw AccessFailure(status: "unsupported", message: "Окно не разрешает изменение position/size") }
        }
    }

    func capture(pid: pid_t, cancellation: Cancellation) throws -> WindowSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let app = AXUIElementCreateApplication(pid)
        let window = try element(read(app, kAXFocusedWindowAttribute, until: deadline, cancellation: cancellation))
        try validate(window, until: deadline, cancellation: cancellation)
        return WindowSnapshot(reference: WindowReference(window),
                              frame: try frame(window, until: deadline, cancellation: cancellation), pid: pid)
    }

    func captureDrag(at point: CGPoint, cancellation: Cancellation) throws -> WindowSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let system = AXUIElementCreateSystemWide()
        try prepare(system, until: deadline, cancellation: cancellation)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard error == .success, let hit else { throw failure(error) }
        let role = try read(hit, kAXRoleAttribute, until: deadline, cancellation: cancellation) as? String
        guard role == "AXTitleBar" || role == kAXWindowRole else {
            throw AccessFailure(status: "unsupported", message: "Начало жеста вне заголовка")
        }
        let window = role == kAXWindowRole ? hit : try element(read(hit, kAXWindowAttribute, until: deadline, cancellation: cancellation))
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            throw AccessFailure(status: "unsupported", message: "Собственное окно")
        }
        let initial = try frame(window, until: deadline, cancellation: cancellation)
        let strip = CGRect(x: initial.minX + 16, y: initial.minY + 5, width: initial.width - 32, height: 27)
        guard strip.contains(point) else { throw AccessFailure(status: "unsupported", message: "Неоднозначная область переноса") }
        try validate(window, until: deadline, cancellation: cancellation)
        return WindowSnapshot(reference: WindowReference(window), frame: initial, pid: pid)
    }

    func currentFrame(_ snapshot: WindowSnapshot, cancellation: Cancellation) throws -> CGRect {
        try frame(snapshot.reference.element, until: ProcessInfo.processInfo.systemUptime + 0.25,
                  cancellation: cancellation)
    }

    private func writeSize(_ window: AXUIElement, _ size: CGSize, until deadline: TimeInterval,
                           cancellation: Cancellation?) throws {
        try prepare(window, until: deadline, cancellation: cancellation)
        var value = size
        let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                                AXValueCreate(.cgSize, &value)!)
        guard error == .success else { throw failure(error) }
    }

    private func writePosition(_ window: AXUIElement, _ point: CGPoint, until deadline: TimeInterval,
                               cancellation: Cancellation?) throws {
        try prepare(window, until: deadline, cancellation: cancellation)
        var value = point
        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                                AXValueCreate(.cgPoint, &value)!)
        guard error == .success else { throw failure(error) }
    }

    private func settle(_ window: AXUIElement, until deadline: TimeInterval,
                        cancellation: Cancellation?) async throws -> CGRect {
        // Separate AX writes because an in-flight window animation can overwrite the previous frame.
        try prepare(window, until: deadline, cancellation: cancellation)
        guard deadline - ProcessInfo.processInfo.systemUptime > 0.175 else {
            throw AccessFailure(status: "failed", message: "Нет времени на проверку стабилизации frame")
        }
        try await Task.sleep(for: .milliseconds(150))
        var previous = try frame(window, until: deadline, cancellation: cancellation)
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(25))
            let current = try frame(window, until: deadline, cancellation: cancellation)
            if GeometryEngine.close(previous, current, tolerance: 0.5) { return current }
            previous = current
        }
        throw AccessFailure(status: "failed", message: "Frame продолжает меняться после AX-записи")
    }

    func place(_ snapshot: WindowSnapshot, at target: CGRect, visibleArea: CGRect?, cancellation: Cancellation) async -> PlacementResult {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 0.9
        let window = snapshot.reference.element
        var before: CGRect?
        var actual: CGRect?
        var wrote = false
        var samples: [FrameSample] = []
        var status = "failed"
        var message = ""
        do {
            try validate(window, until: deadline, cancellation: cancellation)
            let initial = try frame(window, until: deadline, cancellation: cancellation)
            before = initial
            actual = initial
            // Shrink before moving, but defer enlargement until the target origin has room for it.
            let stagingSize = CGSize(width: min(initial.width, target.width),
                                     height: min(initial.height, target.height))
            if abs(stagingSize.width - initial.width) > 2 || abs(stagingSize.height - initial.height) > 2 {
                wrote = true
                try writeSize(window, stagingSize, until: deadline, cancellation: cancellation)
                actual = try await settle(window, until: deadline, cancellation: cancellation)
                samples.append(FrameSample(stage: "after staging shrink", frame: actual!))
            }
            try validate(window, until: deadline, cancellation: cancellation)
            wrote = true
            try writePosition(window, target.origin, until: deadline, cancellation: cancellation)
            actual = try await settle(window, until: deadline, cancellation: cancellation)
            samples.append(FrameSample(stage: "after position", frame: actual!))
            if let measured = actual,
               abs(measured.width - target.width) > 2 || abs(measured.height - target.height) > 2 {
                try validate(window, until: deadline, cancellation: cancellation)
                try writeSize(window, target.size, until: deadline, cancellation: cancellation)
                actual = try await settle(window, until: deadline, cancellation: cancellation)
                samples.append(FrameSample(stage: "after size correction", frame: actual!))
            }
            if let measured = actual {
                // A final size write can move the origin, so reconcile position once after resizing.
                let requested = CGRect(origin: target.origin, size: measured.size)
                let corrected = visibleArea.map { GeometryEngine.keepVisible(requested, in: $0) } ?? requested
                if !GeometryEngine.close(measured, corrected),
                   deadline - ProcessInfo.processInfo.systemUptime >= 0.25 {
                    try validate(window, until: deadline, cancellation: cancellation)
                    try writePosition(window, corrected.origin, until: deadline, cancellation: cancellation)
                    actual = try await settle(window, until: deadline, cancellation: cancellation)
                    samples.append(FrameSample(stage: "after final position correction", frame: actual!))
                }
            }
            guard let actual else { throw AccessFailure(status: "failed", message: "Нет read-back") }
            if GeometryEngine.close(actual, target) {
                status = "exact"
                message = "Окно размещено, отклонение не больше 2 pt"
            } else if let before, GeometryEngine.close(actual, before), !GeometryEngine.close(before, target) {
                status = "unsupported"
                message = "Приложение оставило окно на прежнем месте"
            } else {
                status = "adjusted"
                message = "Приложение скорректировало размер или положение"
            }
        } catch {
            let issue = error as? AccessFailure
            status = issue?.status ?? "failed"
            message = issue?.message ?? "Ошибка AX"
            if wrote, !cancellation.cancelled, let before {
                do {
                    try validate(window, until: start + 1.5, cancellation: cancellation)
                    try writeSize(window, before.size, until: start + 1.5, cancellation: cancellation)
                    _ = try await settle(window, until: start + 1.5, cancellation: cancellation)
                    try writePosition(window, before.origin, until: start + 1.5, cancellation: cancellation)
                    actual = try await settle(window, until: start + 1.5, cancellation: cancellation)
                    message += GeometryEngine.close(actual!, before) ? "; исходный frame восстановлен" : "; восстановление скорректировано приложением"
                } catch {
                    message += "; восстановление не подтверждено"
                }
            }
        }
        return PlacementResult(status: status, message: message, original: before, expected: target,
                               actual: actual, milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), samples: samples)
    }
}
