import CodexAccountCore

func switchStateMachineTests() -> [TestCase] {
    [
        TestCase("SwitchStateMachine allows canonical and journaled recovery transitions") {
            let phases = SwitchStateMachine.canonicalPhases
            try expect(phases.count == 11, "canonical phase count changed")

            for index in 0..<(phases.count - 1) {
                try SwitchStateMachine.validateTransition(from: phases[index], to: phases[index + 1])
            }
            try SwitchStateMachine.validateTransition(from: .quiescent, to: .rollbackStarted)

            try expectError(
                SwitchTransitionError.invalidTransition,
                "phase skipping was accepted"
            ) {
                try SwitchStateMachine.validateTransition(from: .preparing, to: .quiescent)
            }
            try expectError(
                SwitchTransitionError.invalidTransition,
                "phase reversal was accepted"
            ) {
                try SwitchStateMachine.validateTransition(from: .currentSaved, to: .refreshingCurrent)
            }
        },
    ]
}
