/// Wire names for every MCP tool the daemon advertises. Used by each
/// `ToolHandler` conformer's `static var name` and by the registry-driven
/// dispatch in `configureMCPServer`.
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
    case previewBuildInfo = "preview_build_info"
}
