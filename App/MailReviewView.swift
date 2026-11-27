import Directory
import GamEngine
import SwiftUI

/// Reports' Forwarding & mail delegates (roadmap 3.2, GamGUI's `_mail_review.html`): every active account's forwarding that is
/// on and every mail delegate, read when asked. Every account GAM listed is accounted for: read X of N, the unread named with
/// why, the skipped counted, and "none" said only of accounts that were read. Each row opens the person. Reads only.
struct MailReviewPanel: View {
    let reads: MailReviewRead
    let connected: Bool
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Forwarding & mail delegates").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Every active account's Gmail forwarding that is on, and who can read and send as each mailbox, read with GAM "
                     + "when you ask (one Gmail call per account, twice). It doesn\u{2019}t cover Gmail filters that forward, which "
                     + "turning forwarding off doesn\u{2019}t stop either: a person's filters are on their page.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            switch reads.state {
            case nil:
                Button("Read Mail Settings") { read() }
                    .disabled(!connected)
                    .padding(.horizontal)
                    .accessibilityHint("Reads every account's forwarding and delegates. Nothing changes.")
                if !connected { Text("Connect a domain on Setup first.").foregroundStyle(.secondary).padding(.horizontal) }
                Spacer()
            case .reading?:
                HStack { ProgressView().controlSize(.small); Text("Reading every account's forwarding and delegates\u{2026}").foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal)
                Spacer()
            case .read(.failure(let problem), _)?:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't read the mail settings: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor).textSelection(.enabled)
                    Button("Try Again") { read() }.disabled(!connected)
                }
                .padding(.horizontal)
                Spacer()
            case .read(.success(let review), let at)?:
                list(review, at: at)
            }
        }
    }

    private func read() {
        let reads = reads
        Task { await reads.read() }
    }

    private func list(_ review: MailReview, at: Date) -> some View {
        Form {
            Section {
                accounted("Forwarding", review.forwardingAccounts)
                if review.forwarding.isEmpty {
                    Text(review.forwardingAccounts.read > 0 ? "None of the accounts read forwards." : "No account's forwarding was read.")
                        .foregroundStyle(.secondary)
                }
                ForEach(review.forwarding.prefix(MailReviewRead.shown), id: \.self) { row in
                    Button { open(row.user) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.user)
                            Text("\u{2192} \(row.to)" + (row.disposition.isEmpty ? "" : " (\(row.disposition))"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(row.user) on Users.")
                }
                more(review.forwarding.count)
            } header: {
                Text("Forwarding that is on").accessibilityAddTraits(.isHeader)
            }
            Section {
                accounted("Delegates", review.delegationAccounts)
                if review.delegations.isEmpty {
                    Text(review.delegationAccounts.read > 0 ? "None of the accounts read has a delegate." : "No account's delegates were read.")
                        .foregroundStyle(.secondary)
                }
                ForEach(review.delegatedByUser.prefix(MailReviewRead.shown), id: \.user) { group in
                    Button { open(group.user) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.user)
                            ForEach(group.delegations, id: \.self) { d in
                                Text((d.name.isEmpty || d.name == d.delegate ? "" : "\(d.name) ") + "<\(d.delegate)>"
                                     + (d.status.isEmpty ? "" : " \u{B7} \(d.status)"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(group.user) on Users.")
                }
                more(review.delegatedByUser.count)
            } header: {
                Text("Mail delegates").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Read \(at.formatted(date: .omitted, time: .shortened)).")
            }
        }
        .formStyle(.grouped)
    }

    /// GamGUI's line: read X of N, who wasn't read and why, and how many GAM skipped without a word.
    @ViewBuilder private func accounted(_ what: String, _ a: MailReview.Accounted) -> some View {
        Label("\(what): read \(a.read) of \(a.listed) account\(a.listed == 1 ? "" : "s").",
              systemImage: a.complete ? "checkmark.circle" : "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
        ForEach(a.unread, id: \.self) { Text("\($0.user): \($0.why).").font(.callout) }
        if a.skipped > 0 {
            Text("GAM skipped \(a.skipped) account\(a.skipped == 1 ? "" : "s") without a word: their sign-in may have been refused. "
                 + "Nothing here is said about \(a.skipped == 1 ? "it" : "them").")
                .font(.callout)
        }
    }

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > MailReviewRead.shown {
            Text("\u{2026}and \(count - MailReviewRead.shown) more.").foregroundStyle(.secondary)
        }
    }
}
