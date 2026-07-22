import Testing
@testable import eMeishi

struct PrivacyShieldVisibilityStateTests {
    @Test
    func enabledShieldAppearsForInactiveAndRemainsThroughBackground() {
        var state = PrivacyShieldVisibilityState(
            isEnabled: true,
            activity: .active,
            isContentReadyToReveal: true
        )
        #expect(!state.isVisible)

        state.transition(to: .inactive)
        #expect(state.isVisible)

        state.transition(to: .background)
        #expect(state.isVisible)
    }

    @Test
    func returningToActiveKeepsShieldUntilContentIsReady() {
        var state = PrivacyShieldVisibilityState(isEnabled: true, activity: .background)
        #expect(state.isVisible)

        state.transition(to: .active)
        #expect(state.isVisible)

        state.setContentReadyToReveal(true)
        #expect(!state.isVisible)
    }

    @Test
    func leavingActiveInvalidatesPreviousContentReadiness() {
        var state = PrivacyShieldVisibilityState(
            isEnabled: true,
            activity: .active,
            isContentReadyToReveal: true
        )
        #expect(!state.isVisible)

        state.transition(to: .inactive)
        state.transition(to: .active)

        #expect(!state.isContentReadyToReveal)
        #expect(state.isVisible)
    }

    @Test
    func disabledShieldNeverAppearsAcrossLifecycleTransitions() {
        var state = PrivacyShieldVisibilityState(isEnabled: false, activity: .active)

        state.transition(to: .inactive)
        #expect(!state.isVisible)

        state.transition(to: .background)
        #expect(!state.isVisible)
    }

    @Test
    func changingSettingWhileInactiveUpdatesVisibilityImmediately() {
        var state = PrivacyShieldVisibilityState(isEnabled: false, activity: .inactive)
        #expect(!state.isVisible)

        state.setEnabled(true)
        #expect(state.isVisible)

        state.setEnabled(false)
        #expect(!state.isVisible)
    }
}
