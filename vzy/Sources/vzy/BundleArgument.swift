import ArgumentParser
import Foundation
import VZKit

/// Shared `@Argument` for subcommands that take a bundle path. Resolves
/// `~` and relative paths against CWD before constructing the `VMBundle`.
struct BundleArgument: ParsableArguments {
    @Argument(
        help: ArgumentHelp(
            "Path to a vz bundle directory.",
            discussion: "Bundle layout is documented in VZKit.VMBundle."
        )
    )
    var path: String

    func load() throws -> VMBundle {
        let expanded = (path as NSString).expandingTildeInPath
        let url = if expanded.hasPrefix("/") {
            URL(filePath: expanded)
        } else {
            URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: expanded)
        }
        return try VMBundle(directory: url)
    }
}
