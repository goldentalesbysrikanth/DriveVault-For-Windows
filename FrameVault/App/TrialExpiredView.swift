import SwiftUI

struct TrialExpiredView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            VStack(spacing: 10) {
                Text("Your trial has ended")
                    .font(.system(size: 26, weight: .semibold))
                Text("Thank you for trying Drive Vault.\nPurchase a license to continue using the app.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 14) {
                Button {
                    if let url = URL(string: "https://drivevault.app/buy") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Purchase Drive Vault")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 260)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Button {
                    if let url = URL(string: "mailto:support@drivevault.app") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Contact Support")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Drive Vault v1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
