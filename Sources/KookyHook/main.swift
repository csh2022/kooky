import Darwin
import Foundation

// kooky-hook: invoked by an agent's hook system (Claude Code's `--settings`
// hooks, Codex equivalents, …) to ping the running kooky app over a unix
// socket. Exit code is always 0 — agents shouldn't fail because our app
// happens to be closed.
//
// Usage: kooky-hook <event>     where <event> ∈ running | attention | idle
// Reads:  $KOOKY_SURFACE_ID       UUID of the originating session
// Reads:  any stdin               drained but ignored (Claude pipes JSON in)

guard CommandLine.arguments.count >= 2 else { exit(0) }
let event = CommandLine.arguments[1]
let surface = ProcessInfo.processInfo.environment["KOOKY_SURFACE_ID"] ?? ""
guard !surface.isEmpty else { exit(0) }

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let socketPath = support.appendingPathComponent("kooky/socket").path

let payload = #"{"event":"\#(event)","surface":"\#(surface)"}\#n"#

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
guard pathBytes.count < sunPathSize else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { dst in
    pathBytes.withUnsafeBufferPointer { src in
        dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
    }
}

let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { addrPtr in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, len)
    }
}
guard connected == 0 else { exit(0) }

let bytes = Array(payload.utf8)
_ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
