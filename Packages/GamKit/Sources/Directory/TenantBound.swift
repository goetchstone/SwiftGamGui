import ChangeCore
import Setup

extension SetupModel {
    /// Whether `preview` was made on the tenant connected now. A run of one made before a switch (plan F6) is the old
    /// domain's: its screen drops its result (the jobs tray and Audit keep it), as GamGUI's screen reloads for the new domain.
    func isConnected(to preview: HeldPreview) -> Bool {
        active == preview.domain && generation == preview.generation
    }
}
