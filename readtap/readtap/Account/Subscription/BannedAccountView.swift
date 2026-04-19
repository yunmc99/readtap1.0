import SwiftUI

/// Full-screen view displayed when the user's account has been banned.
/// Only allows signing out — no access to any app features.
struct BannedAccountView: View {
    let reason: String?
    @StateObject private var authManager = AuthManager.shared

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red.opacity(0.8))

                Text(AppText.L("Account Suspended", "계정이 정지되었습니다", "账号已被暂停"))
                    .font(.title2.weight(.bold))

                if let reason, !reason.isEmpty {
                    Text(AppText.L("Reason: \(reason)", "사유: \(reason)", "原因：\(reason)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Text(AppText.L(
                    "This account has been suspended by an administrator.\nPlease contact support if you have any questions.",
                    "이 계정은 관리자에 의해 정지되었습니다.\n문의 사항이 있으시면 지원팀에 연락해 주세요.",
                    "此账号已被管理员暂停。\n如有疑问，请联系客服。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                Button {
                    Task { await authManager.signOut() }
                } label: {
                    Text(AppText.L("Sign Out", "로그아웃", "退出登录"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }
}
