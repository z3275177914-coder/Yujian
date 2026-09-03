import OSLog

public enum PerformanceLog {
    public static let subsystem = ImageViewerAppIdentity.bundleIdentifier
    public static let signpostLog = OSLog(
        subsystem: subsystem,
        category: "Performance"
    )

    @discardableResult
    public static func begin(_ name: StaticString) -> OSSignpostID {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(
            .begin,
            log: signpostLog,
            name: name,
            signpostID: signpostID
        )
        return signpostID
    }

    public static func end(
        _ name: StaticString,
        signpostID: OSSignpostID
    ) {
        os_signpost(
            .end,
            log: signpostLog,
            name: name,
            signpostID: signpostID
        )
    }

    public static func event(_ name: StaticString) {
        os_signpost(
            .event,
            log: signpostLog,
            name: name,
            signpostID: .exclusive
        )
    }
}
