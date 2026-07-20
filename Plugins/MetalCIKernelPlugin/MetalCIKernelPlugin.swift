import Foundation
import PackagePlugin

/// Compiles Core Image Metal kernels (`Metal/*.metal`) into `.metallib` resources.
@main
struct MetalCIKernelPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let metalDir = context.package.directoryURL.appending(path: "Metal")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: metalDir.path()))?
            .filter { $0.hasSuffix(".metal") } ?? []

        return names.map { file in
            let stem = (file as NSString).deletingPathExtension
            let metal = metalDir.appending(path: file)
            let air = context.pluginWorkDirectoryURL.appending(path: "\(stem).air")
            let stagedMetallib = context.pluginWorkDirectoryURL.appending(path: "\(stem).staged.metallib")
            let metallib = context.pluginWorkDirectoryURL.appending(path: "\(stem).metallib")
            let script = """
            set -eu
            source=\(shellQuote(metal.path()))
            air=\(shellQuote(air.path()))
            staged=\(shellQuote(stagedMetallib.path()))
            final=\(shellQuote(metallib.path()))
            trap 'rm -f "$air" "$staged"' EXIT
            rm -f "$final"
            xcrun metal -c -fcikernel "$source" -o "$air"
            test -s "$air"
            xcrun metallib -cikernel "$air" -o "$staged"
            test -s "$staged"
            mv -f "$staged" "$final"
            """
            return .buildCommand(
                displayName: "Compile CI kernel \(file)",
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", script],
                inputFiles: [metal],
                outputFiles: [metallib])
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
