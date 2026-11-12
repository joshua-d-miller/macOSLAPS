/*
===============================================================================
 macOSLAPS | Extensions | Service.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     The privileged service. A second LaunchDaemon
     (com.joshua-d-miller.macoslaps-service) starts macOSLAPS -service as
     root on demand: when the app connects to its Mach service, or when a
     file appears in the request folder. The app runs as the logged-in
     user, so it asks this service to check a reveal code, report status,
     or end a grace period early. Only the signed macOSLAPS app may
     connect.

 How it fits:
     XPC (Mach service)   reveal and status: the password needs a reply
                          to a caller whose signature is checked
     Request folder       rotate now from the menu bar: launchd WatchPaths
                          starts the service; it only ends an active grace
                          period
     Deadline timer       the check run itself (Reveal.waitForDeadlineIfSoon)
                          when nobody is logged in

 Used by:
     main.swift (-service, and -reveal / -status / -rotateNow without
     root), the app window and the menu bar agent (step 26c)
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file. A rotate-now request older than
                        claude    the current deadline is ignored. "Will be
                                  logged out" only when the admin is logged
                                  in.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------- //
// | The XPC interface | //
// --------------------- //
// What the app (and macOSLAPS run as a standard user) may ask the root      //
// service. Values cross as plain types; the password only in the reply to a //
// correct reveal.                                                           //
@objc protocol MacOSLAPSServiceProtocol {
    /// One line of -status JSON.
    func status(reply: @escaping (String) -> Void)
    /// ok, the password or an error message, the deadline (ISO 8601 or empty), and
    /// whether the password worked for the account just now.
    func reveal(code: String, reason: String, reply: @escaping (Bool, String, String, Bool) -> Void)
    /// End an active reveal / -expireIn grace period now. false when there is none.
    func rotateNow(reply: @escaping (Bool) -> Void)
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------------- //
// | Names and requirements | //
// -------------------------- //
// The Mach service, the request folder launchd watches, and the code        //
// signature both sides must have (macOSLAPS by team 9UYK4F9BSM).            //
enum Service {
    static let machName = "com.joshua-d-miller.macoslaps.service"
    static let label = "com.joshua-d-miller.macoslaps-service"
    static let checkLabel = "com.joshua-d-miller.macoslaps-check"
    static let requestFolder = "/Library/Application Support/macOSLAPS/Requests"
    static let requirement = "identifier \"com.joshua-d-miller.macoslaps\" and anchor apple generic and certificate leaf[subject.OU] = \"9UYK4F9BSM\""
    /// Exit after this long without a connection; launchd starts the service again on demand.
    static let idleExit : TimeInterval = 30

    /// Starts the check LaunchDaemon now (no-op if it is running), e.g. so it arms the
    /// deadline timer right after a reveal or -expireIn.
    static func kickCheck() {
        _ = Shell.execute(launchPath: "/bin/launchctl", arguments: ["kickstart", "system/\(checkLabel)"], timeout: 15)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------- //
// | Rotate-now requests | //
// ----------------------- //
// A file dropped in the request folder (by the menu bar agent or macOSLAPS  //
// -rotateNow as a user) only ever ends an active grace period early.        //
// Without a deadline it does nothing, so a stray file can't force           //
// rotations.                                                                //
    static func processRequests() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: requestFolder), !files.isEmpty else { return }
        // Only a request made after the current deadline was set may end it: a late
        // request meant for an earlier deadline (e.g. the menu bar agent's, at that
        // deadline) must not cut a new grace period short.
        let setAt = RunState.value("deadlineSetAt").flatMap { RunState.preciseISO.date(from: $0) }
        var current = false
        for f in files {
            let path = (requestFolder as NSString).appendingPathComponent(f)
            let made = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if setAt == nil || (made.map { $0 >= setAt! } ?? false) { current = true }
            try? fm.removeItem(atPath: path)
        }
        guard current else {
            laps_log.print("Ignored a rotate-now request made before the current deadline was set.", .info)
            return
        }
        if endGraceNow(by: "a rotate-now request") {
            laps_log.print("Rotate-now request: the grace period ends now.", .info)
        } else {
            laps_log.print("Ignored a rotate-now request: no reveal or -expireIn deadline is active.", .info)
        }
    }

    /// Moves an active deadline to now and starts the check run. false without a deadline.
    @discardableResult
    static func endGraceNow(by who: String) -> Bool {
        guard Reveal.rotatesAt != nil else { return false }
        RunState.set(["rotatesAt": RunState.iso.string(from: Date())])
        Reveal.appendHistory("rotate now (\(who))")
        kickCheck()
        return true
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------- //
// | The service | //
// --------------- //
// Runs as root when launchd starts it (a connection to the Mach service, or //
// a file in the request folder). Accepts only the signed macOSLAPS app and  //
// exits when idle.                                                          //
    final class Delegate: NSObject, NSXPCListenerDelegate {
        var lastActivity = Date()
        var open = 0
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.setCodeSigningRequirement(Service.requirement)
            connection.exportedInterface = NSXPCInterface(with: MacOSLAPSServiceProtocol.self)
            connection.exportedObject = Handler(uid: connection.effectiveUserIdentifier, delegate: self)
            open += 1; lastActivity = Date()
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { self?.open -= 1; self?.lastActivity = Date() }
            }
            connection.resume()
            return true
        }
    }

    final class Handler: NSObject, MacOSLAPSServiceProtocol {
        let user: String
        weak var delegate: Delegate?
        init(uid: uid_t, delegate: Delegate) {
            user = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "uid \(uid)"
            self.delegate = delegate
        }
        private func touch() { DispatchQueue.main.async { self.delegate?.lastActivity = Date() } }

        func status(reply: @escaping (String) -> Void) {
            touch()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            reply((try? encoder.encode(Status.collect())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        }

        func reveal(code: String, reason: String, reply: @escaping (Bool, String, String, Bool) -> Void) {
            touch()
            guard RunLock.tryAcquire(wait: 60) else {
                reply(false, "macOSLAPS is busy (a rotation is running). Try again in a minute.", "", false)
                return
            }
            defer { RunLock.release() }
            let who = "\(user)" + (reason.isEmpty ? "" : " (reason: \(reason.prefix(200)))")
            switch Reveal.perform(code: code, who: who) {
            case .success(let r):
                Service.kickCheck()
                reply(true, r.password, r.worksUntil.map { RunState.iso.string(from: $0) } ?? "", r.verified)
            case .failure(let f):
                Thread.sleep(forTimeInterval: 1)   // slows down guessing
                reply(false, f.description, "", false)
            }
        }

        func rotateNow(reply: @escaping (Bool) -> Void) {
            touch()
            reply(Service.endGraceNow(by: user))
        }
    }

    static func run() -> Never {
        laps_log.useStandardError = true
        processRequests()
        let delegate = Delegate()
        let listener = NSXPCListener(machServiceName: machName)
        listener.delegate = delegate
        listener.resume()
        // launchd doesn't start a second copy while this one runs, so watch the request
        // folder here too.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            processRequests()
            if delegate.open <= 0 && Date().timeIntervalSince(delegate.lastActivity) > idleExit { exit(0) }
        }
        RunLoop.main.run()
        exit(0)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | The client | //
// -------------- //
// How the app (and macOSLAPS run without root: -reveal, -status,            //
// -rotateNow) talks to the service. The service must carry the same         //
// signature.                                                                //
    static func connection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: machName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: MacOSLAPSServiceProtocol.self)
        c.setCodeSigningRequirement(requirement)
        c.resume()
        return c
    }

    /// Calls the service and waits for the reply (or gives up after `timeout`).
    static func call<T>(timeout: TimeInterval = 90, _ body: (MacOSLAPSServiceProtocol, @escaping (T) -> Void) -> Void) -> T? {
        let c = connection()
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        var result : T?
        var failure : String?
        let proxy = c.remoteObjectProxyWithErrorHandler { error in
            failure = describe(error); done.signal()
        } as? MacOSLAPSServiceProtocol
        guard let service = proxy else { return nil }
        body(service) { value in result = value; done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { failure = "no answer from the macOSLAPS service" }
        if let f = failure { laps_log.print("Could not reach the macOSLAPS service: \(f)", .error) }
        return result
    }

    /// -reveal without root (the code comes from SecretInput, never the command line).
    static func clientReveal(code: String, reason: String) -> Never {
        typealias R = (Bool, String, String, Bool)
        guard let r: R = call({ s, done in s.reveal(code: code, reason: reason) { done(($0, $1, $2, $3)) } }) else { exit(1) }
        guard r.0 else { laps_log.print(r.1, .error); exit(1) }
        print("Local Admin Account: \(Constants.local_admin)")
        print("Password: \(r.1)")
        if let until = RunState.iso.date(from: r.2) {
            let minutes = Int(until.timeIntervalSinceNow / 60)
            print("Works until: \(Constants.dateFormatter.string(from: until)) (\(minutes / 60) h \(minutes % 60) min)")
            if Reveal.logoutApplies(Reveal.action) { print("\(Constants.local_admin) will be logged out at that time.") }
        }
        if !r.3 { print("Warning: this password did not work for \(Constants.local_admin) just now.") }
        exit(0)
    }

    /// -status without root.
    static func clientStatus() -> Never {
        guard let json: String = call({ s, done in s.status { done($0) } }) else { exit(1) }
        print(json)
        exit(0)
    }

    /// -rotateNow: ends an active grace period (any user; root does it directly).
    static func rotateNow() -> Never {
        if getuid() == 0 {
            let ok = endGraceNow(by: "root (command line)")
            print(ok ? "The password changes now." : "No reveal or -expireIn deadline is active.")
            exit(ok ? 0 : 1)
        }
        guard let ok: Bool = call({ s, done in s.rotateNow { done($0) } }) else { exit(1) }
        print(ok ? "The password changes now." : "No reveal or -expireIn deadline is active.")
        exit(ok ? 0 : 1)
    }
}
