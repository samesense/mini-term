import Testing
@testable import MiniTermCore

struct DualRoleKeyboardTests {
    private let caps: UInt16 = 0x39
    private let c: UInt16 = 0x06
    private let a: UInt16 = 0x04
    private let control: UInt16 = 0xE0

    @Test func tapEmitsOnlyEscapeOnRelease() {
        var k = DualRoleKeyboard()
        #expect(k.process(.init(caps, .down, .capsLock)).isEmpty)
        #expect(k.process(.init(caps, .up, .capsLock)) == [
            .synthesize(.init(0x29, .down)), .synthesize(.init(0x29, .up))])
        #expect(k.modifiers.isEmpty)
    }

    @Test func longHoldAndCapsRepeatAreStillATap() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        // Deliberately no timer/threshold: elapsed time has no effect.
        for _ in 0..<100 { #expect(k.process(.init(caps, .repeat)).isEmpty) }
        #expect(k.process(.init(caps, .up)).count == 2)
    }

    @Test(arguments: [UInt16(0x06), UInt16(0x04)])
    func chordHasControlBeforeLetterAndReleasesInOrder(key: UInt16) {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        #expect(k.process(.init(key, .down)) == [
            .synthesize(.init(control, .down, .control)), .forward(.init(key, .down, .control))])
        #expect(k.process(.init(key, .up)) == [.forward(.init(key, .up, .control))])
        #expect(k.process(.init(caps, .up)) == [.synthesize(.init(control, .up))])
    }

    @Test func shiftOptionAndCommandArePreserved() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        let flags: KeyboardModifiers = [.shift, .option, .command, .capsLock]
        let expected: KeyboardModifiers = [.shift, .option, .command, .control]
        #expect(k.process(.init(c, .down, flags)) == [
            .synthesize(.init(control, .down, expected)), .forward(.init(c, .down, expected))])
        #expect(k.modifiers == expected)
    }

    @Test func multipleKeysShareOneControlPress() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        _ = k.process(.init(c, .down))
        #expect(k.process(.init(a, .down)) == [.forward(.init(a, .down, .control))])
        _ = k.process(.init(c, .up))
        #expect(k.process(.init(a, .repeat)) == [.forward(.init(a, .repeat, .control))])
        _ = k.process(.init(a, .up))
        #expect(k.process(.init(caps, .up)) == [.synthesize(.init(control, .up))])
    }

    @Test func releasingCapsFirstRemovesControlFromRepeatsAndRelease() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        _ = k.process(.init(c, .down))
        #expect(k.process(.init(caps, .up)) == [.synthesize(.init(control, .up))])
        #expect(k.process(.init(c, .repeat)) == [.forward(.init(c, .repeat))])
        #expect(k.process(.init(c, .up)) == [.forward(.init(c, .up))])
    }

    @Test func focusLossReleasesLettersBeforeControlWithoutEscape() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        _ = k.process(.init(c, .down))
        _ = k.process(.init(a, .down))
        #expect(k.cancel() == [.forward(.init(a, .up, .control)),
                              .forward(.init(c, .up, .control)), .synthesize(.init(control, .up))])
        #expect(!k.isHeld && k.modifiers.isEmpty)
        #expect(k.cancel().isEmpty)
        #expect(k.process(.init(caps, .up)).isEmpty)
        #expect(k.process(.init(c, .up)).isEmpty)
        #expect(k.process(.init(a, .up)).isEmpty)
        #expect(k.process(.init(c, .down)) == [.forward(.init(c, .down))])
    }

    @Test func pendingTapIsCancelledOnFocusLoss() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down))
        #expect(k.cancel().isEmpty)
        #expect(k.process(.init(caps, .up)).isEmpty)
        _ = k.process(.init(caps, .down))
        #expect(k.process(.init(caps, .up)).count == 2)
    }

    @Test func simultaneousBatchesPutCapsDownFirstAndReleaseLast() {
        var k = DualRoleKeyboard()
        #expect(k.process([.init(c, .down), .init(caps, .down)]) == [
            .synthesize(.init(control, .down, .control)), .forward(.init(c, .down, .control))])
        #expect(k.process([.init(caps, .up), .init(c, .up)]) == [
            .forward(.init(c, .up, .control)), .synthesize(.init(control, .up))])
    }

    @Test func duplicateDownAndUnmatchedUpDoNotCreateExtraEvents() {
        var k = DualRoleKeyboard()
        #expect(k.process(.init(caps, .up)).isEmpty)
        _ = k.process(.init(caps, .down))
        #expect(k.process(.init(caps, .down)).isEmpty)
        _ = k.process(.init(c, .down))
        #expect(k.process(.init(c, .down)).isEmpty)
        _ = k.process(.init(c, .up))
        #expect(k.process(.init(c, .up)).isEmpty)
    }

    @Test func disabledIsExactPassthrough() {
        var k = DualRoleKeyboard(enabled: false)
        for event in [HardwareKeyEvent(caps, .down, .capsLock), .init(c, .down, [.shift, .capsLock]), .init(caps, .up, .capsLock)] {
            #expect(k.process(event) == [.forward(event)])
        }
    }

    @Test func disablingDuringChordBalancesThenSuppressesLateReleases() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down)); _ = k.process(.init(c, .down))
        #expect(k.configure(enabled: false, source: .capsLock).count == 2)
        #expect(k.process(.init(c, .up)).isEmpty)
        #expect(k.process(.init(caps, .up)).isEmpty)
        #expect(k.process(.init(caps, .down)) == [.forward(.init(caps, .down))])
    }

    @Test func remappedControlFallbackHasSameTapAndChordBehavior() {
        var k = DualRoleKeyboard(source: .remappedLeftControl)
        _ = k.process(.init(control, .down, .control))
        #expect(k.modifiers.isEmpty)
        #expect(k.process(.init(control, .up)).first == .synthesize(.init(0x29, .down)))
        _ = k.process(.init(control, .down, .control))
        #expect(k.process(.init(c, .down, .control)).last == .forward(.init(c, .down, .control)))
        _ = k.process(.init(c, .up, .control))
        #expect(k.process(.init(control, .up)) == [.synthesize(.init(control, .up))])
    }

    @Test func keyCommandCountsAsChordButKeepsUpstreamDelivery() {
        var k = DualRoleKeyboard(source: .remappedLeftControl)
        _ = k.process(.init(control, .down, .control))
        #expect(k.keyCommand(modifiers: [.control, .shift]) == [.synthesize(.init(control, .down, [.control, .shift]))])
        #expect(k.process(.init(control, .up)) == [.synthesize(.init(control, .up))])
    }

    @Test func physicalControlAndVirtualControlHaveSingleBalancedOwnership() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(caps, .down)); _ = k.process(.init(c, .down))
        #expect(k.process(.init(control, .down, .control)).isEmpty)
        #expect(k.process(.init(caps, .up, .control)).isEmpty)
        #expect(k.process(.init(control, .up)) == [.forward(.init(control, .up))])
        #expect(k.modifiers.isEmpty)
    }

    @Test func physicalControlReleasedDuringCapsHoldStaysVirtuallyDown() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(control, .down, .control))
        _ = k.process(.init(caps, .down, .control))
        #expect(k.process(.init(c, .down, .control)) == [.forward(.init(c, .down, .control))])
        #expect(k.process(.init(control, .up)).isEmpty)
        #expect(k.cancel().last == .synthesize(.init(control, .up)))
    }

    @Test func enablingDuringAnOrdinaryHoldBalancesItsRelease() {
        var k = DualRoleKeyboard(enabled: false)
        _ = k.process(.init(c, .down))
        #expect(k.configure(enabled: true, source: .capsLock) == [.forward(.init(c, .up))])
        #expect(k.process(.init(c, .up)).isEmpty)
        #expect(k.process(.init(c, .down)) == [.forward(.init(c, .down))])
    }

    @Test func cancellingPhysicalModifiersClearsTheirFlagsInOrder() {
        var k = DualRoleKeyboard()
        _ = k.process(.init(control, .down, .control))
        _ = k.process(.init(0xE1, .down, [.control, .shift]))
        _ = k.process(.init(c, .down, [.control, .shift]))
        #expect(k.cancel() == [.forward(.init(c, .up, [.control, .shift])),
                              .forward(.init(0xE1, .up, .control)), .forward(.init(control, .up))])
    }

    @Test func simultaneousShiftChordOrdersModifiersAroundTheLetter() {
        var k = DualRoleKeyboard()
        #expect(k.process([.init(c, .down, .shift), .init(0xE1, .down, .shift), .init(caps, .down)]) == [
            .synthesize(.init(control, .down, [.control, .shift])),
            .forward(.init(0xE1, .down, [.control, .shift])), .forward(.init(c, .down, [.control, .shift]))])
        #expect(k.process([.init(0xE1, .up), .init(caps, .up), .init(c, .up, .shift)]) == [
            .forward(.init(c, .up, [.control, .shift])), .forward(.init(0xE1, .up, .control)),
            .synthesize(.init(control, .up))])
    }

    @Test func logicalCapsFlagCannotInventPhysicalHoldOrEscape() {
        var k = DualRoleKeyboard()
        #expect(k.process(.init(c, .down, .capsLock)) == [.forward(.init(c, .down))])
        #expect(!k.isHeld)
        #expect(k.process(.init(c, .up, .capsLock)) == [.forward(.init(c, .up))])
        #expect(k.cancel().isEmpty)
    }
}
