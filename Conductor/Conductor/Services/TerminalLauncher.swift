import Foundation
import AppKit

enum TerminalLauncher {
    static func resumeCommand(_ session: Session) throws -> String {
        let nativeID: String
        if session.role == .main || (session.source == .opencode && session.role == .child) {
            nativeID = session.effectiveNativeID
        } else if session.role == .child, let root = session.rootNativeID { nativeID = root }
        else { throw LaunchError.unavailable }
        guard nativeID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,255}$", options: .regularExpression) != nil else {
            throw LaunchError.unavailable
        }
        let directory = session.cwd ?? NSHomeDirectory()
        guard directory.hasPrefix("/"), !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LaunchError.unavailable
        }
        let command: String
        switch session.source {
        case .claude: command = "claude --resume"
        case .codex: command = "codex resume"
        case .opencode: command = "opencode --session"
        }
        return "cd -- \(quote(directory)) && exec \(command) \(quote(nativeID))"
    }

    static func resumeSession(_ session: Session) {
        guard let command = try? resumeCommand(session) else { return }
        launchInTerminal(command)
    }

    static func openDirectory(_ path: String) {
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func launchInTerminal(_ command: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conductor-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("resume.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let content = "#!/bin/bash\n/bin/rm -- \"$0\"\n/bin/rmdir -- \"$(/usr/bin/dirname -- \"$0\")\"\n\(command)\n"
            try content.write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    enum LaunchError: Error { case unavailable }
}
