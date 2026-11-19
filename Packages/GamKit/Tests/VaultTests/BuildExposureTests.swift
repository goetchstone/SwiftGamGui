import Testing
import Vault

@Suite("Build exposure")
struct BuildExposureTests {
    @Test(arguments: [
        (debuggable: true, demo: false, warns: true),    // the operator's Debug build: credentials readable
        (debuggable: true, demo: true, warns: false),    // the demo holds no real credentials
        (debuggable: false, demo: false, warns: false),  // the daily build
        (debuggable: false, demo: true, warns: false),
    ])
    func homeWarnsOnlyWhenRealCredentialsSitInADebuggableBuild(_ c: (debuggable: Bool, demo: Bool, warns: Bool)) {
        #expect(BuildExposure.warns(debuggable: c.debuggable, demo: c.demo) == c.warns)
    }
}
