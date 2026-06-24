
private func _decodeData(_ b64: String, label: String) -> Data {
    guard let data = Data(base64Encoded: b64) else {
        preconditionFailure(
            "EmbedHostAppSourceTool produced invalid base64 for \(label) — rerun `swift build`."
        )
    }
    return data
}

private func _decodeUTF8(_ b64: String, label: String) -> String {
    String(decoding: _decodeData(b64, label: label), as: UTF8.self)
}
