import Darwin

/// Checks shared by the folders that hold credentials in plain text for a while: the per-call run
/// folder (GamEngine's `RuntimeDirectory`) and the guided setup's folder (`SetupFolder`).
package enum FolderSafety {
    /// Whether `path` carries an ACL entry that allows anyone anything: an inherited allow entry would
    /// reach files a `0700` mode is meant to keep private.
    package static func grantsByACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        return allows(acl)
    }

    /// The same, for an open folder: no path to re-point between the check and the use.
    package static func grantsByACL(fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        return allows(acl)
    }

    private static func allows(_ acl: acl_t) -> Bool {
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

    /// An open folder that is this user's and private: no group or other bits, no ACL allow entry.
    package static func isPrivate(fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0 && !grantsByACL(fd: fd)
    }
}
