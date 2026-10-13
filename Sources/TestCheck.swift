import Foundation
import Darwin

// Development checks must fail the test run without deliberately crashing a
// native app and opening macOS's "quit unexpectedly" dialog.
func testCheck(_ condition: @autoclosure () -> Bool,
               _ message: @autoclosure () -> String = "Check failed",
               file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { testFailure(message(), file: file, line: line) }
}

func testFailure(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Never {
    fputs("TEST FAILED: \(file):\(line): \(message)\n", stderr)
    fflush(stderr)
    exit(EXIT_FAILURE)
}
