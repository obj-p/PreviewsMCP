import MCP

/// Tool names for MCP server. Used in both schema definitions and dispatch.
enum ToolName: String {
    case previewList = "preview_list"
    case previewStart = "preview_start"
    case previewSnapshot = "preview_snapshot"
    case previewStop = "preview_stop"
    case previewConfigure = "preview_configure"
    case previewSwitch = "preview_switch"
    case previewElements = "preview_elements"
    case previewTouch = "preview_touch"
    case previewVariants = "preview_variants"
    case simulatorList = "simulator_list"
    case sessionList = "session_list"
}

/// All MCP tool schemas exposed by the daemon. Separated from handler
/// logic so MCPServer.swift stays focused on dispatch + implementation.
func mcpToolSchemas() -> [Tool] {
    [
        Tool(
            name: ToolName.previewList.rawValue,
            description: "List #Preview blocks in a Swift source file",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to a Swift source file"),
                    ])
                ]),
                "required": .array([.string("filePath")]),
            ])
        ),
        Tool(
            name: ToolName.previewStart.rawValue,
            description:
                "Compile and launch a live SwiftUI preview. Returns a session ID. Supports macOS (default) and iOS simulator.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Absolute path to a Swift source file containing #Preview"),
                    ]),
                    "previewIndex": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "0-based index of which #Preview to show (default: 0)"),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("Target platform: 'macos' (default) or 'ios'"),
                    ]),
                    "deviceUDID": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Simulator device UDID (for ios; auto-selects if omitted)"),
                    ]),
                    "headless": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "If false, shows the preview window (default: true)"),
                    ]),
                    "width": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Window width in points (macOS only, default: 400)"),
                    ]),
                    "height": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Window height in points (macOS only, default: 600)"),
                    ]),
                    "projectPath": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Project root path (auto-detected if omitted). Enables importing project types from SPM packages, Bazel swift_library targets, or Xcode projects (.xcodeproj / .xcworkspace)."
                        ),
                    ]),
                    "scheme": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Xcode scheme name (only used for .xcodeproj / .xcworkspace projects). Required when the project contains more than one scheme and none of them match the source file's directory."
                        ),
                    ]),
                    "colorScheme": .object([
                        "type": .string("string"),
                        "enum": .array([.string("light"), .string("dark")]),
                        "description": .string("Color scheme override: 'light' or 'dark'"),
                    ]),
                    "dynamicTypeSize": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("xSmall"), .string("small"), .string("medium"),
                            .string("large"),
                            .string("xLarge"), .string("xxLarge"), .string("xxxLarge"),
                            .string("accessibility1"), .string("accessibility2"),
                            .string("accessibility3"),
                            .string("accessibility4"), .string("accessibility5"),
                        ]),
                        "description": .string(
                            "Dynamic Type size (e.g., 'large', 'accessibility3')"),
                    ]),
                    "locale": .object([
                        "type": .string("string"),
                        "description": .string(
                            "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP')"),
                    ]),
                    "layoutDirection": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("leftToRight"), .string("rightToLeft"),
                        ]),
                        "description": .string(
                            "Layout direction: 'leftToRight' or 'rightToLeft'"),
                    ]),
                    "legibilityWeight": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("regular"), .string("bold"),
                        ]),
                        "description": .string(
                            "Legibility weight: 'regular' or 'bold' (Bold Text accessibility)"
                        ),
                    ]),
                ]),
                "required": .array([.string("filePath")]),
            ])
        ),
        Tool(
            name: ToolName.previewSnapshot.rawValue,
            description:
                "Capture a screenshot of a running preview. Returns the image as JPEG (default) or PNG.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string("Session ID from preview_start"),
                    ]),
                    "quality": .object([
                        "type": .string("number"),
                        "description": .string(
                            "JPEG quality 0.0–1.0 (default: 0.85). Values >= 1.0 produce PNG output."
                        ),
                    ]),
                ]),
                "required": .array([.string("sessionID")]),
            ])
        ),
        Tool(
            name: ToolName.previewStop.rawValue,
            description: "Close a preview and clean up the session.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string("Session ID from preview_start"),
                    ])
                ]),
                "required": .array([.string("sessionID")]),
            ])
        ),
        Tool(
            name: ToolName.previewConfigure.rawValue,
            description:
                "Change rendering traits (color scheme, dynamic type, locale, layout direction, legibility weight) for a running preview. Triggers recompile; @State is reset. Pass empty string to clear a trait. Note: dynamicTypeSize only has a visible effect on iOS simulator — macOS does not scale fonts in response to this modifier.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string("Session ID from preview_start"),
                    ]),
                    "colorScheme": .object([
                        "type": .string("string"),
                        "enum": .array([.string("light"), .string("dark")]),
                        "description": .string("Color scheme override"),
                    ]),
                    "dynamicTypeSize": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("xSmall"), .string("small"), .string("medium"),
                            .string("large"),
                            .string("xLarge"), .string("xxLarge"), .string("xxxLarge"),
                            .string("accessibility1"), .string("accessibility2"),
                            .string("accessibility3"),
                            .string("accessibility4"), .string("accessibility5"),
                        ]),
                        "description": .string("Dynamic Type size override"),
                    ]),
                    "locale": .object([
                        "type": .string("string"),
                        "description": .string(
                            "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP'). Pass empty string to clear."
                        ),
                    ]),
                    "layoutDirection": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Layout direction: 'leftToRight' or 'rightToLeft'. Pass empty string to clear."
                        ),
                    ]),
                    "legibilityWeight": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Legibility weight: 'regular' or 'bold'. Pass empty string to clear."
                        ),
                    ]),
                ]),
                "required": .array([.string("sessionID")]),
            ])
        ),
        Tool(
            name: ToolName.previewSwitch.rawValue,
            description:
                "Switch which #Preview block is rendered in a running session. Triggers recompile; @State is reset. Traits persist across switches.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string("Session ID from preview_start"),
                    ]),
                    "previewIndex": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "0-based index of the #Preview block to switch to"),
                    ]),
                ]),
                "required": .array([.string("sessionID"), .string("previewIndex")]),
            ])
        ),
        Tool(
            name: ToolName.previewElements.rawValue,
            description:
                "Get the accessibility tree of an iOS simulator preview. Returns elements with labels, frames, and traits for targeted interaction.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Session ID from preview_start (iOS simulator only)"),
                    ]),
                    "filter": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("all"), .string("interactable"), .string("labeled"),
                        ]),
                        "description": .string(
                            "Filter mode: 'all' (default) returns the full tree, 'interactable' returns only buttons/links/toggles, 'labeled' returns only elements with label/value/identifier"
                        ),
                    ]),
                ]),
                "required": .array([.string("sessionID")]),
            ])
        ),
        Tool(
            name: ToolName.previewTouch.rawValue,
            description:
                "Send a touch event to an iOS simulator preview. Coordinates are in device points. For swipe, x/y is the start point.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Session ID from preview_start (iOS simulator only)"),
                    ]),
                    "x": .object([
                        "type": .string("number"),
                        "description": .string(
                            "X coordinate in points (start point for swipe)"),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Y coordinate in points (start point for swipe)"),
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("'tap' (default) or 'swipe'"),
                    ]),
                    "toX": .object([
                        "type": .string("number"),
                        "description": .string("End X for swipe"),
                    ]),
                    "toY": .object([
                        "type": .string("number"),
                        "description": .string("End Y for swipe"),
                    ]),
                    "duration": .object([
                        "type": .string("number"),
                        "description": .string("Swipe duration in seconds (default: 0.3)"),
                    ]),
                ]),
                "required": .array([.string("sessionID"), .string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: ToolName.previewVariants.rawValue,
            description:
                "Capture screenshots under multiple trait configurations in a single call. Renders each variant, snapshots it, then restores original traits. Accepts preset names or JSON trait objects.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionID": .object([
                        "type": .string("string"),
                        "description": .string("Session ID from preview_start"),
                    ]),
                    "variants": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Preset name ('light', 'dark', 'xSmall'…'accessibility5', 'rtl', 'ltr', 'boldText') or a JSON object string with any combination of colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight, and an optional label."
                            ),
                        ]),
                        "description": .string(
                            "Array of trait variants to snapshot. Example: [\"light\", \"dark\", \"accessibility3\"]"
                        ),
                    ]),
                    "quality": .object([
                        "type": .string("number"),
                        "description": .string(
                            "JPEG quality 0.0-1.0 (default: 0.85). Values >= 1.0 produce PNG output."
                        ),
                    ]),
                ]),
                "required": .array([.string("sessionID"), .string("variants")]),
            ])
        ),
        Tool(
            name: ToolName.simulatorList.rawValue,
            description: "List available iOS simulator devices with their UDIDs and states.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: ToolName.sessionList.rawValue,
            description:
                "List all active preview sessions in the daemon, with their source file paths and platforms. Used by CLI commands to resolve --file to --session, and for diagnostic tooling.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
    ]
}
