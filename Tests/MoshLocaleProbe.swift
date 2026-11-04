// Physical-iPad locale capability probe. No SSH identity or network access.
import Darwin

struct MoshLocaleProbeView: View {
    @State private var message = "Checking UTF-8 locales…"
    var body: some View {
        Text(message).padding().task {
            var results: [String: Bool] = [:]
            for name in ["en_US.UTF-8", "UTF-8", "C.UTF-8", "C"] {
                let locale = newlocale(LC_CTYPE_MASK, name, nil)
                results[name] = locale != nil
                if let locale { freelocale(locale) }
            }
            let failures = results["UTF-8"] == true ? [] : ["Darwin UTF-8 locale unavailable"]
            let report: [String: Any] = ["checks": 1, "failures": failures, "locales": results]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: URL.documentsDirectory.appendingPathComponent("mosh-locale-probe.json"))
            message = "Locale check finished"
        }
    }
}
