/// The GAM release this app is built and tested against. `scripts/bump_gam.py` rewrites it, together
/// with `fetch_gam.sh`'s TAG, the mock's `gam version` and the regenerated fixtures; a test fails when
/// any of them disagree.
public enum GamVersion {
    public static let expected = "7.48.22"
}
