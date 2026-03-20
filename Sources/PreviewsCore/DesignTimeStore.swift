/// Swift source code for the DesignTimeStore, compiled into every preview dylib.
/// This is a source template, not compiled as part of PreviewsCore.
public enum DesignTimeStoreSource {
    public static let code = """
        import Observation

        @Observable
        final class DesignTimeStore {
            static let shared = DesignTimeStore()
            var values: [String: Any] = [:]

            func string(_ id: String, fallback: String) -> String {
                (values[id] as? String) ?? fallback
            }
            func integer(_ id: String, fallback: Int) -> Int {
                if let v = values[id] as? Int { return v }
                return fallback
            }
            // Overload for CGFloat contexts (VStack spacing, padding, cornerRadius, etc.)
            func integer(_ id: String, fallback: Int) -> CGFloat {
                if let v = values[id] as? Int { return CGFloat(v) }
                return CGFloat(fallback)
            }
            func float(_ id: String, fallback: Double) -> Double {
                if let v = values[id] as? Double { return v }
                return fallback
            }
            // Overload for CGFloat contexts
            func float(_ id: String, fallback: Double) -> CGFloat {
                if let v = values[id] as? Double { return CGFloat(v) }
                return CGFloat(fallback)
            }
            func boolean(_ id: String, fallback: Bool) -> Bool {
                (values[id] as? Bool) ?? fallback
            }
        }

        @_cdecl("designTimeSetString")
        public func designTimeSetString(_ id: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
            DesignTimeStore.shared.values[String(cString: id)] = String(cString: value)
        }

        @_cdecl("designTimeSetInteger")
        public func designTimeSetInteger(_ id: UnsafePointer<CChar>, _ value: Int) {
            DesignTimeStore.shared.values[String(cString: id)] = value
        }

        @_cdecl("designTimeSetFloat")
        public func designTimeSetFloat(_ id: UnsafePointer<CChar>, _ value: Double) {
            DesignTimeStore.shared.values[String(cString: id)] = value
        }

        @_cdecl("designTimeSetBoolean")
        public func designTimeSetBoolean(_ id: UnsafePointer<CChar>, _ value: Bool) {
            DesignTimeStore.shared.values[String(cString: id)] = value
        }
        """
}
