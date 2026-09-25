import Foundation

extension String {
    /// This string IF THE SERVER ACTUALLY RECORDED ONE, else nil.
    ///
    /// ── The one lost distinction no schema can express ──
    ///
    /// Several routes collapse a nullable relation at the response boundary:
    ///
    ///     title:       line.task?.title      ?? ''
    ///     productName: line.product?.name    ?? ''
    ///     doseUnit:    line.doseUnit?.symbol ?? ''
    ///     parcelName:  r.parcel?.name        ?? ''
    ///
    /// Four sites, found by grepping agri-saas for `?.field ?? ''` at a
    /// response boundary (2026-09-25). The field is then `type: string` and
    /// `required` — truthfully, because a string is what arrives — so nothing
    /// in the spec distinguishes "the operator recorded nothing" from "the
    /// operator recorded a value". Both are a string. One is empty.
    ///
    /// This is the THIRD of three ways a string field goes missing, and it is
    /// the only one that is invisible to the contract:
    ///
    ///     ["string","null"]            present and NULL     — schema says so
    ///     plain string, not required    ABSENT entirely      — schema says so
    ///     plain string, required        present and BLANK    — schema cannot
    ///
    /// The server's instruction is to filter these out of a concatenation
    /// rather than render a placeholder, and empty means "not recorded" and
    /// never "unknown" — so there is nothing to apologise for on screen, only
    /// a part to leave out.
    ///
    /// ── What it cost before it had a name ──
    ///
    /// `doseText` interpolated the unit regardless, so every unitless line
    /// carried a trailing space: invisible in a diff, visible in a
    /// right-aligned column. The mirror image happened in `LocationsView`,
    /// where an absent `kind` left a leading «·» in front of the parcel
    /// count. Two renderings of one defect, a week apart, neither caught by a
    /// test — because both produced valid strings.
    ///
    /// Whitespace counts as not recorded. A value of `"  "` is not something
    /// a farmer typed on purpose, and it renders identically to the empty
    /// case while defeating an `isEmpty` check.
    var recorded: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
