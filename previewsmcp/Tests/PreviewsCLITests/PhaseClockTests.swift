import Foundation
import MCP
@testable import PreviewsCLI
import PreviewsCore
import Testing

@Suite("Phase clock")
struct PhaseClockTests {
    actor RecordingReporter: ProgressReporter {
        private(set) var reports: [String] = []
        private(set) var ticks: [String] = []

        func report(_: BuildPhase, message: String) async {
            reports.append(message)
        }

        func tick(message: String, elapsed _: Duration) async {
            ticks.append(message)
        }
    }

    @Test("phase() ticks while the work runs and stops when it returns")
    func tickerRunsDuringWork() async throws {
        let reporter = RecordingReporter()

        try await reporter.phase(
            .buildingProject, "Building...", interval: .milliseconds(40)
        ) {
            try await Task.sleep(for: .milliseconds(150))
        }
        let ticksAtReturn = await reporter.ticks.count
        try await Task.sleep(for: .milliseconds(120))

        #expect(await reporter.reports == ["Building..."])
        #expect(ticksAtReturn >= 2)
        #expect(await reporter.ticks.count == ticksAtReturn)
    }

    @Test("phase() emits no tick for work faster than the interval")
    func fastWorkDoesNotTick() async throws {
        let reporter = RecordingReporter()

        try await reporter.phase(
            .buildingProject, "Building...", interval: .seconds(5)
        ) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await reporter.ticks.isEmpty)
    }

    @Test("a throwing work body still cancels the ticker and rethrows")
    func throwingWorkCancelsTicker() async throws {
        struct Boom: Error {}
        let reporter = RecordingReporter()

        await #expect(throws: Boom.self) {
            try await reporter.phase(
                .rendering, "Rendering...", interval: .milliseconds(30)
            ) {
                try await Task.sleep(for: .milliseconds(80))
                throw Boom()
            }
        }
        let ticksAtThrow = await reporter.ticks.count
        try await Task.sleep(for: .milliseconds(100))

        #expect(await reporter.ticks.count == ticksAtThrow)
    }

    @Test("a nil reporter runs the work with no clock machinery")
    func nilReporterRunsBare() async throws {
        let reporter: (any ProgressReporter)? = nil
        let value = try await withPhase(reporter, .rendering, "Rendering...") {
            42
        }

        #expect(value == 42)
    }

    actor RecordingServer: MCPServing {
        private(set) var logLines: [String] = []
        private(set) var progressValues: [Double] = []

        func withMethodHandler<M: MCP.Method>(
            _: M.Type,
            handler _: @escaping @Sendable (M.Parameters) async throws -> M.Result
        ) -> Self {
            self
        }

        func start(transport _: any Transport) async throws {}
        func stop() async {}
        func waitUntilCompleted() async {}

        func notify(_ notification: Message<some MCP.Notification>) async throws {
            if let params = notification.params as? ProgressNotification.Parameters {
                progressValues.append(params.progress)
            }
        }

        func log(level _: LogLevel, logger _: String?, data: Value) async throws {
            if case let .string(line) = data {
                logLines.append(line)
            }
        }
    }

    @Test("MCP tick holds the step number and keeps token progress monotonic")
    func mcpTickHoldsStep() async {
        let server = RecordingServer()
        let reporter = MCPProgressReporter(
            server: server, progressToken: .string("t"), totalSteps: 4
        )

        await reporter.report(.detectingProject, message: "Detecting project...")
        await reporter.report(.buildingProject, message: "Building...")
        await reporter.tick(message: "Building...", elapsed: .seconds(5))
        await reporter.tick(message: "Building...", elapsed: .seconds(10))
        await reporter.report(.compilingBridge, message: "Compiling...")

        let lines = await server.logLines
        #expect(lines == [
            "[1/4] Detecting project...",
            "[2/4] Building...",
            "[2/4] Building... (5s)",
            "[2/4] Building... (10s)",
            "[3/4] Compiling...",
        ])
        let progress = await server.progressValues
        #expect(progress == progress.sorted())
        #expect(progress.last == 3.0)
        #expect(progress[2] > 2.0 && progress[2] < 3.0)
    }
}
