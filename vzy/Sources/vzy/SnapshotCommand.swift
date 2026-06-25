import ArgumentParser
import Foundation
import VZKit

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Take / restore / list named APFS-clone snapshots of a bundle's disk state.",
        subcommands: [Take.self, Restore.self, List.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct Take: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "take",
            abstract: "Snapshot the bundle's disk.img + aux.img under <bundle>/snapshots/<name>/."
        )
        @OptionGroup var bundle: BundleArgument
        @Argument(help: "Snapshot name (becomes a directory name).") var name: String

        func run() async throws {
            let bundle = try bundle.load()
            _ = try SnapshotStore.take(name: name, of: bundle)
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Rewind the bundle's disk.img + aux.img to a named snapshot. VM must be stopped."
        )
        @OptionGroup var bundle: BundleArgument
        @Argument(help: "Snapshot name to restore.") var name: String

        func run() async throws {
            let bundle = try bundle.load()
            try SnapshotStore.restore(name: name, in: bundle)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List snapshots in <bundle>/snapshots/."
        )
        @OptionGroup var bundle: BundleArgument

        func run() async throws {
            let bundle = try bundle.load()
            let snapshots = try SnapshotStore.list(in: bundle)
            if snapshots.isEmpty {
                print("(no snapshots in \(SnapshotStore.snapshotsDirectory(for: bundle).path))")
                return
            }
            let formatter = ISO8601DateFormatter()
            for snapshot in snapshots {
                print("\(snapshot.name)\t\(formatter.string(from: snapshot.createdAt))")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a snapshot directory."
        )
        @OptionGroup var bundle: BundleArgument
        @Argument(help: "Snapshot name to delete.") var name: String

        func run() async throws {
            let bundle = try bundle.load()
            try SnapshotStore.delete(name: name, in: bundle)
        }
    }
}
