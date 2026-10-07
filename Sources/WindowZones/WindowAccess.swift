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

struct FillCandidate: Sendable {
    let id: UUID
    let snapshot: WindowSnapshot
    let title: String
    let minimized: Bool
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
    var axCode: Int32? = nil
}

actor WindowAccess {
    private func failure(_ error: AXError, operation: String) -> AccessFailure {
        let status: String
        switch error {
        case .apiDisabled: status = "denied"
        case .attributeUnsupported, .notImplemented: status = "unsupported"
        default: status = "failed"
        }
        return AccessFailure(status: status, message: "\(operation): AX error \(error.rawValue)", axCode: error.rawValue)
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
        guard error == .success else { throw failure(error, operation: "set messaging timeout") }
    }

    private func read(_ element: AXUIElement, _ name: String, until deadline: TimeInterval,
                      cancellation: Cancellation? = nil) throws -> CFTypeRef {
        try prepare(element, until: deadline, cancellation: cancellation)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { throw failure(error, operation: "read \(name)") }
        guard let value else {
            throw AccessFailure(status: "failed", message: "read \(name): пустой результат AX")
        }
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
                          cancellation: Cancellation? = nil, allowMinimized: Bool = false) throws {
        let role = try read(window, kAXRoleAttribute, until: deadline, cancellation: cancellation) as? String
        let subrole = try read(window, kAXSubroleAttribute, until: deadline, cancellation: cancellation) as? String
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else {
            throw AccessFailure(status: "unsupported", message: "Поддерживаются только обычные окна")
        }
        let minimized = try read(window, kAXMinimizedAttribute, until: deadline, cancellation: cancellation) as? Bool
        guard minimized == false || (allowMinimized && minimized == true) else { throw AccessFailure(status: "unsupported", message: "Окно свёрнуто или статус неизвестен") }
        // Some apps expose resize and fullscreen capabilities only after restoring from Dock.
        if allowMinimized && minimized == true { return }
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
            guard error == .success else { throw failure(error, operation: "check settable \(attribute)") }
            guard settable.boolValue else { throw AccessFailure(status: "unsupported", message: "Окно не разрешает изменение position/size") }
        }
    }

    func capture(pid: pid_t, cancellation: Cancellation) throws -> WindowSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let app = AXUIElementCreateApplication(pid)
        let window: AXUIElement
        do {
            window = try element(read(app, kAXFocusedWindowAttribute, until: deadline, cancellation: cancellation))
        } catch let issue as AccessFailure {
            // Record only window availability, never window titles or contents.
            guard !cancellation.cancelled, issue.status != "denied" else { throw issue }
            let main = try? read(app, kAXMainWindowAttribute, until: deadline, cancellation: cancellation)
            let windows = try? read(app, kAXWindowsAttribute, until: deadline, cancellation: cancellation)
            let count = (windows as? [AXUIElement]).map { String($0.count) } ?? "unknown"
            let unavailable = issue.axCode == AXError.noValue.rawValue
            let explanation = unavailable ? "Приложение не предоставило активное окно. Открой обычное окно и повтори. " : ""
            throw AccessFailure(status: unavailable ? "unsupported" : issue.status,
                                message: "\(explanation)\(issue.message); AXMainWindow: \(main == nil ? "unavailable" : "available"); AXWindows count: \(count)",
                                axCode: issue.axCode)
        }
        try validate(window, until: deadline, cancellation: cancellation)
        return WindowSnapshot(reference: WindowReference(window),
                              frame: try frame(window, until: deadline, cancellation: cancellation), pid: pid)
    }

    // The caller must freeze this candidate before validating its window capabilities.
    func captureDragCandidate(at point: CGPoint, cancellation: Cancellation) throws -> WindowSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let system = AXUIElementCreateSystemWide()
        try prepare(system, until: deadline, cancellation: cancellation)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard error == .success else { throw failure(error, operation: "hit test") }
        guard let hit else { throw AccessFailure(status: "failed", message: "hit test: пустой результат AX") }
        let role = try read(hit, kAXRoleAttribute, until: deadline, cancellation: cancellation) as? String
        // Only passive title surfaces may lead to a toolbar candidate, never controls or tabs.
        guard let role, DragStartSurface.allowsTraversal(role) else {
            throw AccessFailure(status: "unsupported", message: "Начало жеста вне заголовка")
        }
        var toolbar: AXUIElement?
        var ancestor = hit
        var ancestorRole = role
        for _ in 0..<12 {
            if ancestorRole == "AXToolbar" { toolbar = ancestor; break }
            if ancestorRole == kAXWindowRole || ancestorRole == "AXTitleBar" { break }
            guard DragStartSurface.allowsTraversal(ancestorRole) else {
                throw AccessFailure(status: "unsupported", message: "Интерактивный элемент панели инструментов (\(ancestorRole))")
            }
            ancestor = try element(read(ancestor, kAXParentAttribute, until: deadline, cancellation: cancellation))
            ancestorRole = try read(ancestor, kAXRoleAttribute, until: deadline, cancellation: cancellation) as? String ?? ""
        }
        guard toolbar != nil || ancestorRole == kAXWindowRole || ancestorRole == "AXTitleBar" else {
            throw AccessFailure(status: "unsupported", message: "Не удалось подтвердить область заголовка")
        }
        let window = role == kAXWindowRole ? hit : try element(read(hit, kAXWindowAttribute, until: deadline, cancellation: cancellation))
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            throw AccessFailure(status: "unsupported", message: "Собственное окно")
        }
        let initial = try frame(window, until: deadline, cancellation: cancellation)
        let toolbarFrame = try toolbar.map { try frame($0, until: deadline, cancellation: cancellation) }
        guard DragStartSurface.contains(point, window: initial, role: role, toolbar: toolbarFrame) else {
            throw AccessFailure(status: "unsupported", message: "Неоднозначная область переноса (\(role), toolbar=\(toolbar != nil))")
        }
        return WindowSnapshot(reference: WindowReference(window), frame: initial, pid: pid)
    }

    func unusedCandidateIDs(_ candidates: [FillCandidate], excluding: [WindowSnapshot]) -> Set<UUID> {
        Set(candidates.filter { candidate in
            !excluding.contains { CFEqual($0.reference.element, candidate.snapshot.reference.element) }
        }.map(\.id))
    }

    func fillCandidates(pids: [pid_t], area: CGRect, excluding: [WindowSnapshot], previous: [FillCandidate] = [],
                        cancellation: Cancellation) async -> [FillCandidate] {
        var result: [FillCandidate] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for pid in pids {
            guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
            let app = AXUIElementCreateApplication(pid)
            let appDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.3)
            guard let windows = try? read(app, kAXWindowsAttribute, until: appDeadline, cancellation: cancellation) as? [AXUIElement] else { continue }
            for window in windows.prefix(20) {
                guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
                if excluding.contains(where: { CFEqual($0.reference.element, window) }) { continue }
                if result.contains(where: { CFEqual($0.snapshot.reference.element, window) }) { continue }
                let windowDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.3)
                do {
                    try validate(window, until: windowDeadline, cancellation: cancellation, allowMinimized: true)
                    let minimized = (try? read(window, kAXMinimizedAttribute, until: windowDeadline, cancellation: cancellation)) as? Bool ?? false
                    // Minimized windows may omit geometry; placement reads it again after restoration.
                    let measured = try? frame(window, until: windowDeadline, cancellation: cancellation)
                    guard let rect = measured ?? (minimized ? CGRect.zero : nil) else { continue }
                    let intersection = rect.intersection(area)
                    guard minimized || (!intersection.isNull && intersection.width * intersection.height > 0) else { continue }
                    // Titles are transient UI labels and are never included in diagnostics.
                    let title = (try? read(window, kAXTitleAttribute, until: windowDeadline, cancellation: cancellation)) as? String ?? ""
                    result.append(FillCandidate(id: previous.first(where: { CFEqual($0.snapshot.reference.element, window) })?.id ?? UUID(), snapshot: WindowSnapshot(reference: WindowReference(window), frame: rect, pid: pid),
                                                title: String(title.prefix(160)), minimized: minimized))
                } catch { continue }
            }
            await Task.yield()
        }
        return result
    }

    func restoreForFill(_ candidate: FillCandidate, cancellation: Cancellation) async throws {
        let window = candidate.snapshot.reference.element
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        try validate(window, until: deadline, cancellation: cancellation, allowMinimized: true)
        let minimized = try read(window, kAXMinimizedAttribute, until: deadline, cancellation: cancellation) as? Bool
        guard minimized == true else { return }
        try prepare(window, until: deadline, cancellation: cancellation)
        let error = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard error == .success else { throw failure(error, operation: "restore minimized window") }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if cancellation.cancelled { throw CancellationError() }
            if (try? read(window, kAXMinimizedAttribute, until: deadline, cancellation: cancellation)) as? Bool == false {
                try validate(window, until: deadline, cancellation: cancellation)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AccessFailure(status: "failed", message: "Окно не восстановилось из Dock")
    }

    func validateTarget(_ snapshot: WindowSnapshot, cancellation: Cancellation) throws {
        try validate(snapshot.reference.element, until: ProcessInfo.processInfo.systemUptime + 0.25,
                     cancellation: cancellation)
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
        guard error == .success else { throw failure(error, operation: "write AXSize") }
    }

    private func writePosition(_ window: AXUIElement, _ point: CGPoint, until deadline: TimeInterval,
                               cancellation: Cancellation?) throws {
        try prepare(window, until: deadline, cancellation: cancellation)
        var value = point
        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                                AXValueCreate(.cgPoint, &value)!)
        guard error == .success else { throw failure(error, operation: "write AXPosition") }
    }

    private func settle(_ window: AXUIElement, until deadline: TimeInterval,
                        cancellation: Cancellation?) async throws -> CGRect {
        // Separate AX writes because an in-flight window animation can overwrite the previous frame.
        try prepare(window, until: deadline, cancellation: cancellation)
        guard deadline - ProcessInfo.processInfo.systemUptime > 0.25 else {
            throw AccessFailure(status: "failed", message: "Нет времени на проверку стабилизации frame")
        }
        try await Task.sleep(for: .milliseconds(150))
        var stability = FrameStability()
        let initial = try frame(window, until: deadline, cancellation: cancellation)
        _ = stability.observe(initial, at: ProcessInfo.processInfo.systemUptime)
        while deadline - ProcessInfo.processInfo.systemUptime > 0.025 {
            try prepare(window, until: deadline, cancellation: cancellation)
            try await Task.sleep(for: .milliseconds(25))
            let current = try frame(window, until: deadline, cancellation: cancellation)
            if stability.observe(current, at: ProcessInfo.processInfo.systemUptime) { return current }
        }
        throw AccessFailure(status: "failed", message: "Frame не стабилизировался в пределах бюджета AX")
    }

    func place(_ snapshot: WindowSnapshot, at target: CGRect, visibleArea: CGRect?, cancellation: Cancellation) async -> PlacementResult {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 1.4
        let window = snapshot.reference.element
        var before: CGRect?
        var actual: CGRect?
        var wrote = false
        var samples: [FrameSample] = []
        var status = "failed"
        var message = ""
        var stage = "initial validation"
        do {
            try validate(window, until: deadline, cancellation: cancellation)
            stage = "initial frame"
            let initial = try frame(window, until: deadline, cancellation: cancellation)
            before = initial
            actual = initial
            // Shrink before moving, but defer enlargement until the target origin has room for it.
            let stagingSize = CGSize(width: min(initial.width, target.width),
                                     height: min(initial.height, target.height))
            if abs(stagingSize.width - initial.width) > 2 || abs(stagingSize.height - initial.height) > 2 {
                stage = "staging shrink"
                wrote = true
                try writeSize(window, stagingSize, until: deadline, cancellation: cancellation)
                actual = try await settle(window, until: deadline, cancellation: cancellation)
                samples.append(FrameSample(stage: "after staging shrink", frame: actual!))
            }
            stage = "target position"
            try validate(window, until: deadline, cancellation: cancellation)
            wrote = true
            try writePosition(window, target.origin, until: deadline, cancellation: cancellation)
            actual = try await settle(window, until: deadline, cancellation: cancellation)
            samples.append(FrameSample(stage: "after position", frame: actual!))
            if let measured = actual,
               abs(measured.width - target.width) > 2 || abs(measured.height - target.height) > 2 {
                stage = "size correction"
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
                   deadline - ProcessInfo.processInfo.systemUptime >= 0.35 {
                    stage = "final position correction"
                    try validate(window, until: deadline, cancellation: cancellation)
                    try writePosition(window, corrected.origin, until: deadline, cancellation: cancellation)
                    actual = try await settle(window, until: deadline, cancellation: cancellation)
                    samples.append(FrameSample(stage: "after final position correction", frame: actual!))
                }
            }
            // An animated resize or display transition may leave a transient size adjustment.
            // Retry once at the settled origin without looping on app size constraints.
            if let positioned = actual,
               abs(positioned.width - target.width) > 2 || abs(positioned.height - target.height) > 2,
               deadline - ProcessInfo.processInfo.systemUptime >= 0.65 {
                stage = "settled size retry"
                try validate(window, until: deadline, cancellation: cancellation)
                try writeSize(window, target.size, until: deadline, cancellation: cancellation)
                actual = try await settle(window, until: deadline, cancellation: cancellation)
                samples.append(FrameSample(stage: "after settled size retry", frame: actual!))
                if let resized = actual {
                    let requested = CGRect(origin: target.origin, size: resized.size)
                    let corrected = visibleArea.map { GeometryEngine.keepVisible(requested, in: $0) } ?? requested
                    if !GeometryEngine.close(resized, corrected),
                       deadline - ProcessInfo.processInfo.systemUptime >= 0.35 {
                        stage = "retry position correction"
                        try validate(window, until: deadline, cancellation: cancellation)
                        try writePosition(window, corrected.origin, until: deadline, cancellation: cancellation)
                        actual = try await settle(window, until: deadline, cancellation: cancellation)
                        samples.append(FrameSample(stage: "after retry position correction", frame: actual!))
                    }
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
            message = "\(stage): \(issue?.message ?? "Ошибка AX")"
            // Samples retain earlier measurements, but a failed write may have changed the frame.
            actual = nil
            if wrote, !cancellation.cancelled, let before {
                do {
                    let recoveryDeadline = start + 2
                    stage = "rollback validation"
                    try validate(window, until: recoveryDeadline, cancellation: cancellation)
                    stage = "rollback frame"
                    var recovered = try frame(window, until: recoveryDeadline, cancellation: cancellation)
                    // Shrink before returning across displays, but enlarge only at the original origin.
                    let stagingSize = CGSize(width: min(recovered.width, before.width),
                                             height: min(recovered.height, before.height))
                    if abs(stagingSize.width - recovered.width) > 2 || abs(stagingSize.height - recovered.height) > 2 {
                        stage = "rollback staging shrink"
                        try writeSize(window, stagingSize, until: recoveryDeadline, cancellation: cancellation)
                        recovered = try await settle(window, until: recoveryDeadline, cancellation: cancellation)
                        samples.append(FrameSample(stage: "after rollback staging shrink", frame: recovered))
                    }
                    if abs(recovered.minX - before.minX) > 2 || abs(recovered.minY - before.minY) > 2 {
                        stage = "rollback position"
                        try validate(window, until: recoveryDeadline, cancellation: cancellation)
                        try writePosition(window, before.origin, until: recoveryDeadline, cancellation: cancellation)
                        recovered = try await settle(window, until: recoveryDeadline, cancellation: cancellation)
                        samples.append(FrameSample(stage: "after rollback position", frame: recovered))
                    }
                    if abs(recovered.width - before.width) > 2 || abs(recovered.height - before.height) > 2 {
                        stage = "rollback size"
                        try validate(window, until: recoveryDeadline, cancellation: cancellation)
                        try writeSize(window, before.size, until: recoveryDeadline, cancellation: cancellation)
                        recovered = try await settle(window, until: recoveryDeadline, cancellation: cancellation)
                        samples.append(FrameSample(stage: "after rollback size", frame: recovered))
                    }
                    if (abs(recovered.minX - before.minX) > 2 || abs(recovered.minY - before.minY) > 2),
                       recoveryDeadline - ProcessInfo.processInfo.systemUptime >= 0.35 {
                        stage = "rollback final position"
                        try validate(window, until: recoveryDeadline, cancellation: cancellation)
                        try writePosition(window, before.origin, until: recoveryDeadline, cancellation: cancellation)
                        recovered = try await settle(window, until: recoveryDeadline, cancellation: cancellation)
                        samples.append(FrameSample(stage: "after rollback final position", frame: recovered))
                    }
                    actual = recovered
                    message += GeometryEngine.close(actual!, before) ? "; исходный frame восстановлен" : "; восстановление скорректировано приложением"
                } catch {
                    let rollbackIssue = error as? AccessFailure
                    message += "; восстановление не подтверждено (\(stage): \(rollbackIssue?.message ?? "операция прервана"))"
                }
            }
        }
        return PlacementResult(status: status, message: message, original: before, expected: target,
                               actual: actual, milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), samples: samples)
    }
}
