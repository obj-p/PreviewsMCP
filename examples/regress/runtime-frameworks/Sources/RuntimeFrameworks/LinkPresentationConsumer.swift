import LinkPresentation

enum LinkPresentationConsumer {
    static func metadata(title: String) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
    }
}
