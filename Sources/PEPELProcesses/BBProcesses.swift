import Foundation
import PEPELCore

/// Recognises BB's processes: the app and its server and daemon, the per-thread provider workers
/// (with the agent and its MCP servers below them), and its plugins' processes, including ones
/// a plugin left running on their own (such as a speech model server).
public enum BBProcesses {
    static func isBB(_ p: ProcessSnapshot) -> Bool {
        let path = p.executablePath ?? ""
        return path.contains("/bb.app/Contents/") || (p.arguments.first ?? "").contains("/bb.app/Contents/")
    }

    public static func isRuntimeWorker(_ p: ProcessSnapshot) -> Bool {
        isBB(p) && p.arguments.contains { $0.hasSuffix("bb-provider-bridge-worker.mjs") }
    }

    static func isPluginWorker(_ p: ProcessSnapshot) -> Bool {
        isBB(p) && p.arguments.contains { $0.hasSuffix("bb-plugin-host-worker.mjs") }
    }

    /// An agent started by BB for one of its threads.
    public static func isRuntime(_ p: ProcessSnapshot, ancestors: [ProcessSnapshot]) -> Bool {
        ancestors.contains(where: isRuntimeWorker)
    }

    /// The plugin a process belongs to, from `~/.bb/plugins/<name>/…` or a plugin worker's arguments.
    static func pluginName(_ p: ProcessSnapshot, home: String) -> String? {
        let marker = home + "/.bb/plugins/"
        for text in [p.executablePath ?? ""] + p.arguments where text.hasPrefix(marker) || text.contains("/.bb/plugin-host-artifacts/") {
            if text.hasPrefix(marker) { return String(text.dropFirst(marker.count).split(separator: "/").first ?? "") }
            if let range = text.range(of: "/.bb/plugin-host-artifacts/") { return String(text[range.upperBound...].split(separator: "/").first ?? "") }
        }
        return nil
    }

    public struct Usage: Sendable {
        public var running = false
        public var runtimeCount = 0
        public var runtimeBytes: Int64 = 0
        public var runtimeProcesses = 0
        public var appBytes: Int64 = 0
        public var plugins: [String: (bytes: Int64, count: Int)] = [:]
    }

    /// What BB holds right now, split into the app, thread runtimes and plugins.
    public static func usage(_ processes: [ProcessSnapshot], home: String) -> Usage {
        let tree = ProcessTree(processes)
        var usage = Usage()
        var counted = Set<ProcessIdentity>()
        for worker in processes where isRuntimeWorker(worker) {
            let all = [worker] + tree.descendants(of: worker)
            usage.runtimeCount += 1
            usage.runtimeProcesses += all.count
            usage.runtimeBytes += all.reduce(0) { $0 + $1.footprintBytes }
            counted.formUnion(all.map(\.identity))
        }
        for p in processes where !counted.contains(p.identity) {
            let plugin = pluginName(p, home: home) ?? (isPluginWorker(p) ? "plugin" : nil)
            if let plugin, !(isRuntimeWorker(p)) {
                let name = plugin.hasPrefix("provider-") ? String(plugin.dropFirst("provider-".count)) : plugin
                let current = usage.plugins[name] ?? (0, 0)
                usage.plugins[name] = (current.bytes + p.footprintBytes, current.count + 1)
                counted.insert(p.identity)
                continue
            }
            if isBB(p) {
                usage.running = true
                usage.appBytes += p.footprintBytes
                counted.insert(p.identity)
            }
        }
        // What a plugin worker starts (esbuild, a model server) belongs to that plugin.
        for p in processes where !counted.contains(p.identity) {
            if let owner = tree.ancestors(of: p).first(where: isPluginWorker), let name = pluginName(owner, home: home) {
                let current = usage.plugins[name] ?? (0, 0)
                usage.plugins[name] = (current.bytes + p.footprintBytes, current.count + 1)
            } else if tree.ancestors(of: p).contains(where: isBB) {
                usage.appBytes += p.footprintBytes
            }
        }
        return usage
    }
}
