/*
===============================================================================
 macOSLAPS | Tests | main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-11

 Purpose:
     Tests for Shell.execute (macOSLAPS/Extensions/Shell.swift). No root
     needed.
     1. Output larger than the 64 KB pipe buffer must not deadlock.
     2. stderr is captured with stdout, the trailing newline trimmed, the
     exit status kept.
     3. A tool that never exits is stopped at the timeout.

 Usage:
     swiftc macOSLAPS/Extensions/Shell.swift Tests/ShellTests/main.swift \
         -o shell-tests && ./shell-tests
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Checks | //
// ---------- //
var failures = 0
func expect(_ ok: Bool, _ message: String) { if !ok { failures += 1; print("FAIL: \(message)") } else { print("PASS: \(message)") } }

// 1. Output larger than the 64 KB pipe buffer must not deadlock (the old code hung here).
let start = Date()
let big = Shell.execute(launchPath: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1000 count=300 2>/dev/null | tr '\\000' x"], timeout: 20)
expect(!big.timedOut && big.status == 0, "300 KB of output finishes (status \(big.status), timedOut \(big.timedOut))")
expect(big.output.count == 300000, "all 300 KB captured (got \(big.output.count))")
expect(Date().timeIntervalSince(start) < 15, "large output returns promptly")

// 2. stderr is captured with stdout, trailing newline trimmed, exit status kept.
let mixed = Shell.execute(launchPath: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
expect(mixed.status == 3, "exit status preserved (\(mixed.status))")
expect(mixed.output.contains("out") && mixed.output.contains("err") && !mixed.output.hasSuffix("\n"), "stdout+stderr captured, newline trimmed")

// 3. A tool that never exits is stopped at the timeout.
let t0 = Date()
let stuck = Shell.execute(launchPath: "/bin/sleep", arguments: ["30"], timeout: 2)
expect(stuck.timedOut && stuck.status == -1, "stuck tool reported as timed out")
expect(Date().timeIntervalSince(t0) < 10, "stuck tool stopped within the timeout")

// 4. A missing tool fails cleanly.
let missing = Shell.execute(launchPath: "/nonexistent/tool", arguments: [])
expect(missing.status == -1 && missing.output.isEmpty, "missing tool returns status -1")

// 5. The legacy API still returns just the output.
expect(Shell.run(launchPath: "/bin/echo", arguments: ["hello"]) == "hello", "Shell.run returns trimmed output")

print(failures == 0 ? "All shell tests passed" : "\(failures) shell test(s) failed")
exit(failures == 0 ? 0 : 1)
