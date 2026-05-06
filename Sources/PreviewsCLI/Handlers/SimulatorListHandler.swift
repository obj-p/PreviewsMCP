import MCP

enum SimulatorListHandler: ToolHandler {
    static let name: ToolName = .simulatorList

    static let schema = Tool(
        name: ToolName.simulatorList.rawValue,
        description: "List available iOS simulator devices with their UDIDs and states.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let manager = await ctx.iosState.simulatorManager
        let devices = try await manager.listDevices()
        let available = devices.filter { $0.isAvailable }

        let structured = DaemonProtocol.SimulatorListResult(
            simulators: available.map { device in
                DaemonProtocol.SimulatorDTO(
                    udid: device.udid,
                    name: device.name,
                    runtime: device.runtimeName,
                    state: device.stateString,
                    isAvailable: device.isAvailable
                )
            }
        )

        if available.isEmpty {
            return try CallTool.Result(
                content: [.text("No available simulator devices found.")],
                structuredContent: structured
            )
        }

        var lines: [String] = []
        for device in available {
            let state = device.state == .booted ? " [BOOTED]" : ""
            lines.append("\(device.name) — \(device.udid)\(state) (\(device.runtimeName ?? "unknown runtime"))")
        }

        return try CallTool.Result(
            content: [.text(lines.joined(separator: "\n"))],
            structuredContent: structured
        )
    }
}
