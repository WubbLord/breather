import Foundation

@main struct TestCheckTests {
    static func main() throws {
        if CommandLine.arguments.contains("--fail-check") {
            testCheck(false, "Expected failure probe", file: "FailureProbe.swift", line: 42)
        }
        if CommandLine.arguments.contains("--fail-callback") {
            DispatchQueue.main.async {
                testFailure("Expected callback failure", file: "CallbackProbe.swift", line: 17)
            }
            RunLoop.main.run()
            testFailure("Callback did not exit")
        }
        var evaluations = 0
        testCheck(true, { evaluations += 1; return "Unused diagnostic" }())
        testCheck(evaluations == 0, "Successful checks must not evaluate failure diagnostics")
        for (flag, diagnostic) in [
            ("--fail-check", "TEST FAILED: FailureProbe.swift:42: Expected failure probe"),
            ("--fail-callback", "TEST FAILED: CallbackProbe.swift:17: Expected callback failure")
        ] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [flag]
            let errors = Pipe(); child.standardError = errors
            try child.run(); child.waitUntilExit()
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            testCheck(child.terminationReason == .exit && child.terminationStatus == 1,
                      "A failed check must exit with status 1 rather than a crash signal")
            testCheck(output.contains(diagnostic), "Failed checks must retain their source location and diagnostic")
        }
        print("Test failure reporting passed: synchronous and callback failures exit normally with status 1 and useful diagnostics")
    }
}
