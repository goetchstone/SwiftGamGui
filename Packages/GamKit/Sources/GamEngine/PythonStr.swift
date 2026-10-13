extension JSONValue {
    /// Python's `str()` of what `json.loads` made of this value, as GamGUI's screens print a record's field:
    /// text as it is, `True`, `None`, a number as Python prints it (`1e+16`, `-0.0`). A list or an object is
    /// written as JSON, where Python prints its repr: neither app writes one where text is expected.
    package var pythonText: String {
        switch self {
        case .array, .object: JSONValue.dumps(self)
        default: Fields.text(self)
        }
    }
}
