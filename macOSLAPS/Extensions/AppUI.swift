/*
===============================================================================
 macOSLAPS | App | AppUI.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     The macOSLAPS app: the window a technician uses to reveal the
     password with a code (device mode) or to see the status (escrow
     mode), and the menu bar agent that counts down to the next change.
     Both run as the logged-in user and ask the root service
     (Service.swift) for anything privileged.

 How it fits:
     Window      /Applications/macOSLAPS.app opened from Finder: status,
                 code + reason, password (large, phonetic, copy with
                 auto-clear), when it stops working, Done
     Menu bar    LaunchAgent com.joshua-d-miller.macoslaps.agent (-agent):
                 lock + "ladmin | 3:42", warning color in the last 15
                 minutes, notifications, Done, Open macOSLAPS

 Known limitations:
     Not exercised by CI (no screen): checked by testers. Strings are
     English; they go through NSLocalizedString for later translation.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file. The window and menu say the
                        claude    admin will be logged out only when it is
                                  logged in.
===============================================================================
*/

import AppKit
import Combine
import SwiftUI
import UserNotifications

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------- //
// | Starting the app | //
// -------------------- //
// The same executable is the command, the daemon and the app. Opened from   //
// Finder (no arguments, no terminal) as a user it shows the window; -agent  //
// runs the menu bar countdown.                                              //
enum AppUI {
    /// Kept here because NSApplication holds its delegate weakly.
    static var delegate : NSApplicationDelegate?

    /// Opened from Finder or Launchpad: a user, no arguments, no terminal attached.
    static var openedAsApp : Bool {
        getuid() != 0 && CommandLine.arguments.dropFirst().allSatisfy { $0.hasPrefix("-psn_") } && isatty(STDIN_FILENO) == 0
    }

    static func run(_ appDelegate: NSApplicationDelegate, accessory: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(accessory ? .accessory : .regular)
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
        exit(0)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------- //
// | Words | //
// --------- //
// Every sentence the app and the menu bar show, in one place so they can be //
// translated (Localizable.strings) and match the design.                    //
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    /// "3 h 42 min" / "12 min".
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? t("%d h %d min", minutes / 60, minutes % 60) : t("%d min", minutes)
    }

    /// "3:42" for the menu bar.
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------------- //
// | Reading a password aloud | //
// ---------------------------- //
// NATO words for letters (Capital / small), digit names, and symbol names.  //
    static let nato = ["Alfa", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India",
                       "Juliett", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo",
                       "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"]
    static let digits = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
    static let symbols : [Character: String] = ["-": "Dash", "_": "Underscore", ".": "Period", ",": "Comma",
        "!": "Exclamation", "?": "Question", "@": "At", "#": "Hash", "$": "Dollar", "%": "Percent",
        "^": "Caret", "&": "Ampersand", "*": "Asterisk", "(": "Open paren", ")": "Close paren",
        "+": "Plus", "=": "Equals", "/": "Slash", "\\": "Backslash", ":": "Colon", ";": "Semicolon",
        "'": "Apostrophe", "\"": "Quote", "<": "Less than", ">": "Greater than", "[": "Open bracket",
        "]": "Close bracket", "{": "Open brace", "}": "Close brace", "|": "Pipe", "~": "Tilde", "`": "Backtick"]

    static func phonetic(_ password: String) -> String {
        password.map { c -> String in
            if let a = c.asciiValue, c.isLetter {
                let word = nato[Int((c.uppercased().first!.asciiValue ?? 65) - 65)]
                return a < 97 ? "Capital \(word)" : "small \(word.lowercased())"
            }
            if let d = c.wholeNumberValue, c.isASCII { return digits[d] }
            return symbols[c] ?? String(c)
        }.joined(separator: ", ")
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------- //
// | The window's data | //
// --------------------- //
// Asks the root service (XPC) for status and to reveal; never stores the    //
// password beyond the window's life.                                        //
final class AppModel: ObservableObject {
    @Published var status : [String: Any] = [:]
    @Published var code = ""
    @Published var reason = ""
    @Published var password : String?
    @Published var worksUntil : Date?
    @Published var verified = true
    @Published var message : String?
    @Published var busy = false
    @Published var showPhonetic = false
    @Published var now = Date()
    private var clearToken = 0

    var account : String { status["account"] as? String ?? Constants.local_admin }
    var deviceMode : Bool { (status["retrievalMode"] as? String) == "device" }
    var deadline : Date? { (status["rotatesAt"] as? String).flatMap(RunState.iso.date(from:)) ?? worksUntil }

    func refresh() {
        DispatchQueue.global().async {
            let json : String? = Service.call(timeout: 30) { s, done in s.status { done($0) } }
            let parsed = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            DispatchQueue.main.async {
                if let p = parsed { self.status = p } else { self.message = AppUI.t("The macOSLAPS service did not answer.") }
            }
        }
    }

    func reveal() {
        busy = true; message = nil
        let code = self.code, reason = self.reason
        DispatchQueue.global().async {
            typealias R = (Bool, String, String, Bool)
            let r : R? = Service.call { s, done in s.reveal(code: code, reason: reason) { done(($0, $1, $2, $3)) } }
            DispatchQueue.main.async {
                self.busy = false
                guard let r = r else { self.message = AppUI.t("The macOSLAPS service did not answer."); return }
                if r.0 {
                    self.password = r.1
                    self.worksUntil = RunState.iso.date(from: r.2)
                    self.verified = r.3
                    self.code = ""
                    self.refresh()
                } else {
                    self.message = r.1
                }
            }
        }
    }

    func rotateNow() {
        DispatchQueue.global().async {
            let ok : Bool? = Service.call(timeout: 30) { s, done in s.rotateNow { done($0) } }
            DispatchQueue.main.async {
                if ok == true {
                    self.password = nil
                    self.message = AppUI.t("The password for %@ changes now.", self.account)
                }
                self.refresh()
            }
        }
    }

    /// Copies the password and clears the clipboard after 60 seconds if it still holds it.
    func copy() {
        guard let pw = password else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(pw, forType: .string)
        clearToken += 1
        let token = clearToken, count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if token == self.clearToken && board.changeCount == count { board.clearContents() }
        }
        message = AppUI.t("Copied. The clipboard is cleared in 60 seconds.")
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | The window | //
// -------------- //
// Device mode: enter the code (and why), then the password in large type    //
// with a phonetic option, when it stops working, and Done. Escrow mode:     //
// status only.                                                              //
struct MainView: View {
    @ObservedObject var model: AppModel
    let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppUI.t("Local Admin Account: %@", model.account)).font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.deviceMode {
                if let pw = model.password { revealed(pw) } else { entry }
            }
            statusLines
            if let message = model.message {
                Text(message).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { model.refresh() }
        .onReceive(tick) { model.now = $0 }
    }

    var entry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppUI.t("Enter the reveal code from your MDM to show the password."))
            TextField(AppUI.t("Reveal code"), text: $model.code)
                .font(.system(.title3, design: .monospaced))
                .accessibilityLabel(AppUI.t("Reveal code"))
            TextField(AppUI.t("Reason or ticket (optional)"), text: $model.reason)
                .accessibilityLabel(AppUI.t("Reason or ticket"))
            Button(AppUI.t("Reveal Password")) { model.reveal() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || model.code.trimmingCharacters(in: .whitespaces).count < 16)
        }
    }

    func revealed(_ pw: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pw).font(.system(size: 26, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(AppUI.t("Password: %@", AppUI.phonetic(pw)))
            if model.showPhonetic {
                Text(AppUI.phonetic(pw)).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.verified {
                Text(AppUI.t("This password did not work for %@ just now.", model.account)).foregroundColor(.orange)
            }
            HStack {
                Button(AppUI.t("Copy")) { model.copy() }
                Button(model.showPhonetic ? AppUI.t("Hide Phonetic") : AppUI.t("Show Phonetic")) { model.showPhonetic.toggle() }
                Spacer()
                Button(AppUI.t("Done — Rotate Now")) { model.rotateNow() }
            }
        }
    }

    var statusLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let deadline = model.deadline {
                Text(AppUI.t("Password works until %@ (%@)", AppUI.time(deadline), AppUI.remaining(deadline.timeIntervalSince(model.now))))
                if (model.status["rotateReason"] as? String) != nil, Reveal.logoutApplies(Reveal.action) {
                    Text(AppUI.t("%@ will be logged out at that time.", model.account)).foregroundColor(.secondary)
                }
            } else if let expires = (model.status["expires"] as? String).flatMap(RunState.iso.date(from:)) {
                Text(AppUI.t("Next scheduled change: %@", DateFormatter.localizedString(from: expires, dateStyle: .medium, timeStyle: .short)))
            }
            if let works = model.status["passwordVerifies"] as? Bool {
                Text(works ? AppUI.t("The stored password works.") : AppUI.t("The stored password does not work. Contact IT."))
                    .foregroundColor(works ? .secondary : .red)
            }
            if (model.status["revealLocked"] as? Bool) == true {
                Text(AppUI.t("Reveals are locked after too many wrong codes. Contact IT.")).foregroundColor(.red)
            }
        }
        .font(.callout)
    }
}

final class WindowDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window : NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "macOSLAPS"
        w.contentView = NSHostingView(rootView: MainView(model: AppModel()))
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------- //
// | The menu bar agent | //
// ---------------------- //
// Runs in the user's session (LaunchAgent, -agent) only while a deadline    //
// exists: the countdown, the 15-minute warning, a notice when the password  //
// was revealed, Done, and a rotate-now request at the deadline. Reads only  //
// the world-readable deadline file, never the password.                     //
enum Agent {
    struct Deadline {
        let account: String
        let rotatesAt: Date
        let action: String
        let reason: String
        let revealedAt: Date?
    }

    static func read() -> Deadline? {
        guard let data = FileManager.default.contents(atPath: Reveal.deadlineFile),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let account = d["account"] as? String,
              let at = (d["rotatesAt"] as? String).flatMap(RunState.iso.date(from:)) else { return nil }
        return Deadline(account: account, rotatesAt: at, action: d["action"] as? String ?? "rotate",
                        reason: d["reason"] as? String ?? "", revealedAt: (d["revealedAt"] as? String).flatMap(RunState.iso.date(from:)))
    }

    static func run() -> Never {
        // Nothing to count down: exit before touching the window server.
        guard read() != nil else { exit(0) }
        AppUI.run(AgentDelegate(), accessory: true)
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var item : NSStatusItem?
    var timer : Timer?
    var warned = false
    var noticedReveal : Date?
    var requested = false
    var last : Agent.Deadline?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "macOSLAPS"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func tick() {
        guard let d = Agent.read() else {
            if let gone = last {
                notify(AppUI.t("Local Admin Account: %@. The password has changed.", gone.account))
            }
            item.map { NSStatusBar.system.removeStatusItem($0) }
            item = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            timer?.invalidate()
            return
        }
        last = d
        let left = d.rotatesAt.timeIntervalSinceNow
        if d.reason == "reveal", let at = d.revealedAt, noticedReveal != at {
            noticedReveal = at
            notify(AppUI.t("The local admin password for %@ was revealed at %@. It changes at %@.", d.account, AppUI.time(at), AppUI.time(d.rotatesAt)))
        }
        if left <= 15 * 60 && left > 0 && !warned {
            warned = true
            notify(AppUI.t("Local Admin Account: %@. The password changes in %@.", d.account, AppUI.remaining(left)))
        }
        if left <= 0 && !requested {
            requested = true
            FileManager.default.createFile(atPath: Service.requestFolder + "/agent-\(getuid())", contents: nil)
        }
        show(d, left: left)
    }

    func show(_ d: Agent.Deadline, left: TimeInterval) {
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: AppUI.t("macOSLAPS"))
        button.imagePosition = .imageLeading
        let title = " \(d.account) | \(AppUI.short(left))"
        let color : NSColor = left <= 15 * 60 ? .systemOrange : .labelColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color])
        button.setAccessibilityLabel(AppUI.t("Local Admin Account: %@. Password works for %@.", d.account, AppUI.remaining(left)))

        let menu = NSMenu()
        menu.addItem(withTitle: AppUI.t("Local Admin Account: %@", d.account), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: AppUI.t("Password works until %@ (%@)", AppUI.time(d.rotatesAt), AppUI.remaining(left)), action: nil, keyEquivalent: "")
        if Reveal.logoutApplies(d.action) {
            menu.addItem(withTitle: AppUI.t("%@ will be logged out at that time.", d.account), action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let done = NSMenuItem(title: AppUI.t("Done — Rotate Now"), action: #selector(rotateNow), keyEquivalent: "")
        done.target = self
        menu.addItem(done)
        let open = NSMenuItem(title: AppUI.t("Open macOSLAPS…"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item?.menu = menu
    }

    @objc func rotateNow() {
        DispatchQueue.global().async {
            _ = Service.call(timeout: 30) { (s: MacOSLAPSServiceProtocol, done: @escaping (Bool) -> Void) in s.rotateNow { done($0) } }
        }
    }

    @objc func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/macOSLAPS.app"))
    }
}
