/// HID usages, not characters or manufacturer-specific scan codes.
public enum DualRoleKeySource: String, CaseIterable, Sendable {
    case capsLock
    /// iPad Settings → Hardware Keyboard → Modifier Keys → Caps Lock → Control.
    case remappedLeftControl

    public var usage: UInt16 { self == .capsLock ? 0x39 : 0xE0 }
}

public struct KeyboardModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public static let capsLock = Self(rawValue: 16)
}

public struct HardwareKeyEvent: Equatable, Sendable {
    public enum Phase: Sendable { case down, up, `repeat` }
    public var usage: UInt16
    public var phase: Phase
    public var modifiers: KeyboardModifiers
    public init(_ usage: UInt16, _ phase: Phase, _ modifiers: KeyboardModifiers = []) {
        self.usage = usage; self.phase = phase; self.modifiers = modifiers
    }
}

/// The host forwards native events through its existing keyboard pipeline. Only
/// Control and Escape are synthesized; text, layout, IME and repeat stay there.
public enum KeyboardDispatch: Equatable, Sendable {
    case forward(HardwareKeyEvent)
    case synthesize(HardwareKeyEvent)
}

public struct DualRoleKeyboard: Sendable {
    public private(set) var enabled: Bool
    public private(set) var source: DualRoleKeySource
    public private(set) var isHeld = false
    public private(set) var usedAsModifier = false
    private var physicalModifiers: KeyboardModifiers = []
    private var held: [UInt16] = []
    private var cancelled: Set<UInt16> = []
    private var virtualControl = false

    public init(enabled: Bool = true, source: DualRoleKeySource = .capsLock) {
        self.enabled = enabled; self.source = source
    }

    public var modifiers: KeyboardModifiers {
        var result = physicalModifiers.subtracting(.capsLock)
        if source == .remappedLeftControl && !held.contains(0xE4) { result.remove(.control) }
        if virtualControl { result.insert(.control) }
        return result
    }

    /// Batches have no ordering in UIPressesEvent. Resolve ties consistently:
    /// dual key down first, dual key up last. Preserve order outside each batch.
    public mutating func process(_ events: [HardwareKeyEvent]) -> [KeyboardDispatch] {
        events.enumerated().sorted { a, b in
            func rank(_ e: HardwareKeyEvent) -> Int {
                if e.usage == source.usage { return e.phase == .up ? 4 : 0 }
                if (0xE0...0xE7).contains(e.usage) { return e.phase == .up ? 3 : 1 }
                return 2
            }
            return rank(a.element) == rank(b.element) ? a.offset < b.offset : rank(a.element) < rank(b.element)
        }.flatMap { process($0.element) }
    }

    public mutating func process(_ event: HardwareKeyEvent) -> [KeyboardDispatch] {
        if event.phase == .down { cancelled.remove(event.usage) }
        if cancelled.contains(event.usage) {
            if event.phase == .up { cancelled.remove(event.usage) }
            return []
        }
        guard enabled else {
            physicalModifiers = event.modifiers
            if event.phase == .down && !held.contains(event.usage) { held.append(event.usage) }
            if event.phase == .up { held.removeAll { $0 == event.usage } }
            return [.forward(event)]
        }
        physicalModifiers = event.modifiers
        if event.usage == source.usage {
            switch event.phase {
            case .down:
                if !isHeld { isHeld = true; usedAsModifier = false }
                return []
            case .repeat: return []
            case .up:
                guard isHeld else { return [] }
                isHeld = false
                if usedAsModifier {
                    virtualControl = false
                    // A physical left Control pressed during the chord now owns it.
                    return held.contains(0xE0) ? [] : [.synthesize(.init(0xE0, .up, modifiers))]
                }
                return [.synthesize(.init(0x29, .down)), .synthesize(.init(0x29, .up))]
            }
        }
        var output: [KeyboardDispatch] = []
        switch event.phase {
        case .down:
            guard !held.contains(event.usage) else { return [] }
            output = markChord()
            let leftControlAlreadyDown = virtualControl && event.usage == 0xE0
            held.append(event.usage)
            if leftControlAlreadyDown { return output }
        case .up:
            guard let index = held.firstIndex(of: event.usage) else { return [] }
            held.remove(at: index)
            if virtualControl && event.usage == 0xE0 { return [] }
        case .repeat:
            guard held.contains(event.usage) else { return [] }
        }
        var forwarded = event
        forwarded.modifiers = modifiers
        output.append(.forward(forwarded))
        return output
    }

    /// UIKeyCommand has no physical phases. Keep its existing paired-key path,
    /// but record a chord so a later dual-key release cannot emit Escape.
    public mutating func keyCommand(modifiers: KeyboardModifiers) -> [KeyboardDispatch] {
        guard enabled else { return [] }
        physicalModifiers = modifiers
        return markChord()
    }

    private mutating func markChord() -> [KeyboardDispatch] {
        guard isHeld, !usedAsModifier else { return [] }
        usedAsModifier = true
        virtualControl = true
        return held.contains(0xE0) ? [] : [.synthesize(.init(0xE0, .down, modifiers))]
    }

    /// Focus loss, disconnect and setting changes release in reverse press
    /// order. No Escape is generated; late releases are swallowed once.
    public mutating func cancel() -> [KeyboardDispatch] {
        var output: [KeyboardDispatch] = []
        var remaining = Set(held)
        var releaseModifiers = modifiers
        for usage in held.reversed() {
            remaining.remove(usage)
            if [0xE1, 0xE5].contains(usage), remaining.isDisjoint(with: [0xE1, 0xE5]) { releaseModifiers.remove(.shift) }
            if [0xE2, 0xE6].contains(usage), remaining.isDisjoint(with: [0xE2, 0xE6]) { releaseModifiers.remove(.option) }
            if [0xE3, 0xE7].contains(usage), remaining.isDisjoint(with: [0xE3, 0xE7]) { releaseModifiers.remove(.command) }
            if [0xE0, 0xE4].contains(usage), !virtualControl, remaining.isDisjoint(with: [0xE0, 0xE4]) { releaseModifiers.remove(.control) }
            if !(virtualControl && usage == 0xE0) { output.append(.forward(.init(usage, .up, releaseModifiers))) }
        }
        cancelled.formUnion(held)
        if isHeld { cancelled.insert(source.usage) }
        held.removeAll()
        isHeld = false
        usedAsModifier = false
        let releaseControl = virtualControl
        virtualControl = false
        physicalModifiers = []
        if releaseControl { output.append(.synthesize(.init(0xE0, .up))) }
        return output
    }

    public mutating func configure(enabled: Bool, source: DualRoleKeySource) -> [KeyboardDispatch] {
        guard self.enabled != enabled || self.source != source else { return [] }
        let releases = cancel()
        self.enabled = enabled; self.source = source
        return releases
    }
}
