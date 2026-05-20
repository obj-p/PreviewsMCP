import ArgumentParser
import Foundation
import PreviewsVMKit

/// Shared `@Argument` for subcommands that take a bundle path. Resolves
/// `~` and relative paths against CWD before constructing the `VMBundle`.
struct BundleArgument: ParsableArguments {
    @Argument(
        help: ArgumentHelp(
            "Path to a previewsvm bundle directory.",
            discussion: "Bundle layout is documented in PreviewsVM.VMBundle."
        )
    )
    var path: String

    func load() throws -> VMBundle {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(filePath: expanded)
        } else {
            url = URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: expanded)
        }
        return try VMBundle(directory: url)
    }
}
