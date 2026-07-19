import AppKit
import SwiftUI

public struct SupportBrainstormView: View {
    @Binding private var dontShowAgain: Bool
    private let openDestination: (SupportBrainstormDestination) -> Void
    private let maybeLater: () -> Void

    public init(
        dontShowAgain: Binding<Bool>,
        openDestination: @escaping (SupportBrainstormDestination) -> Void,
        maybeLater: @escaping () -> Void
    ) {
        _dontShowAgain = dontShowAgain
        self.openDestination = openDestination
        self.maybeLater = maybeLater
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                title
                introduction
                primaryAction
                sponsorshipSection
                footer
            }
            .padding(28)
        }
        .scrollIndicators(.automatic)
        .frame(
            minWidth: 540,
            idealWidth: 540,
            maxWidth: 540,
            minHeight: 600,
            idealHeight: 620,
            maxHeight: 700
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: some View {
        Text("Support Brainstorm")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 64, height: 64)
                .background(
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                )
                .accessibilityHidden(true)

            Text("Thanks for using Brainstorm")
                .font(.title2.weight(.semibold))

            Text(
                "Brainstorm is independently built and shared as open source. If it’s useful, following the author helps more people discover it. You can also support ongoing development."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Text("No pressure—thanks for being here.")
                .font(.body.weight(.medium))
        }
        .frame(maxWidth: 450)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var primaryAction: some View {
        Button {
            openDestination(.xProfile)
        } label: {
            Label("Follow @selfhosted_ai on X", systemImage: "heart.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.blue)
        .padding(.top, 22)
        .accessibilityHint("Opens the X profile in your default browser")
    }

    private var sponsorshipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Support open-source development")
                .font(.headline)
                .padding(.top, 24)

            sponsorshipRow(
                title: "Sponsor on GitHub",
                description: "Support ongoing development",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: .githubSponsors
            )
            sponsorshipRow(
                title: "Support on Patreon",
                description: "Become a recurring supporter",
                systemImage: "person.crop.circle.badge.plus",
                destination: .patreon
            )
            sponsorshipRow(
                title: "Buy Me a Coffee",
                description: "Send a one-time thank-you",
                systemImage: "cup.and.saucer.fill",
                destination: .buyMeACoffee
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sponsorshipRow(
        title: String,
        description: String,
        systemImage: String,
        destination: SupportBrainstormDestination
    ) -> some View {
        Button {
            openDestination(destination)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(description)")
        .accessibilityHint("Opens in your default browser")
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("Don’t show this again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)

            Spacer(minLength: 16)

            Button("Maybe later", action: maybeLater)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.top, 24)
    }
}

#Preview("Support Brainstorm — Light") {
    SupportBrainstormView(
        dontShowAgain: .constant(false),
        openDestination: { _ in },
        maybeLater: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Support Brainstorm — Dark") {
    SupportBrainstormView(
        dontShowAgain: .constant(false),
        openDestination: { _ in },
        maybeLater: {}
    )
    .preferredColorScheme(.dark)
}
