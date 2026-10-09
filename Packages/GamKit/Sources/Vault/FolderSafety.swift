import Darwin

/// Checks shared by the folders that hold credentials in plain text for a while: the per-call run
/// folder (GamEngine's `RuntimeDirectory`) and the guided setup's folder (`SetupFolder`).
package enum FolderSafety {
    /// Whether `path` carries an ACL entry that allows anyone anything: an inherited allow entry would
    /// reach files a `0700` mode is meant to keep private.
    package static func grantsByACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            var tag = acl_tag_t(rawValue: 0)
            if acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_ALLOW { return true }
            which = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        return false
    }
}
