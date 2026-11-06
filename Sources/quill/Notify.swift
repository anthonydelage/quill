import Foundation

/// Play a macOS system sound (`/System/Library/Sounds/<name>.aiff`) without
/// blocking. Sound, unlike a banner, gets through Focus modes and disabled
/// notifications, so it carries events the user must hear in the moment.
func playSound(_ name: String) {
    let task = Process()
    task.launchPath = "/usr/bin/afplay"
    task.arguments = ["/System/Library/Sounds/\(name).aiff"]
    try? task.run()
}

/// Best-effort user-visible notification. osascript keeps us free of
/// UserNotifications entitlement requirements (which need an app bundle).
func notifyUser(title: String, body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}
