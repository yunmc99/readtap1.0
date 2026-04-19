import SwiftUI

// MARK: - Terms of Service

struct TermsOfServiceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var pad: Bool { DSLayout.isPad }
    private var textColor: Color { colorScheme == .dark ? .white : Color(red: 0.12, green: 0.15, blue: 0.20) }
    private var mutedColor: Color { colorScheme == .dark ? Color.white.opacity(0.5) : Color(red: 0.12, green: 0.15, blue: 0.20).opacity(0.5) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: pad ? 24 : 18) {
                        legalSection(
                            title: AppText.L("1. Service Overview", "1. 서비스 개요", "1. 服务概述"),
                            body: AppText.L(
                                "ReadTap (the \"App\") is an iOS application that lets you long-press unknown words in PDF and image-based reading materials to instantly see definitions, and save vocabulary for review. These Terms govern your use of the App.",
                                "ReadTap(이하 \"앱\")은 PDF 및 이미지 기반 읽기 자료에서 모르는 단어를 길게 눌러 뜻을 확인하고, 어휘를 저장·복습할 수 있는 iOS 어플리케이션입니다. 본 약관은 앱 이용에 관한 조건을 규정합니다.",
                                "ReadTap（以下简称「应用」）是一款 iOS 应用程序，可让您在 PDF 和图片阅读材料中长按生词即时查看释义，并保存词汇进行复习。本条款规定了您使用本应用的条件。")
                        )

                        legalSection(
                            title: AppText.L("2. Eligibility", "2. 이용 자격", "2. 使用资格"),
                            body: AppText.L(
                                "The App is intended for users aged 13 and older. By downloading or using the App, you agree to be bound by these Terms.",
                                "본 앱은 만 13세 이상의 사용자를 대상으로 합니다. 앱을 다운로드하거나 사용하면 본 약관에 동의한 것으로 간주됩니다.",
                                "本应用面向13岁及以上用户。下载或使用本应用即表示您同意受本条款约束。")
                        )

                        legalSection(
                            title: AppText.L("3. User Content", "3. 사용자 콘텐츠", "3. 用户内容"),
                            body: AppText.L(
                                "PDF and image files you import into the App are stored locally on your device and are not uploaded to our servers. Saved vocabulary data is kept in an on-device SQLite database. You are responsible for ensuring you have the right to use any content you import.",
                                "사용자가 앱에 가져오는 PDF 및 이미지 파일은 사용자의 기기에 로컬로 저장되며, 당사 서버로 업로드되지 않습니다. 저장된 어휘 데이터는 기기 내 SQLite 데이터베이스에 보관됩니다. 사용자는 자신이 가져오는 콘텐츠에 대한 저작권 및 법적 책임을 집니다.",
                                "您导入应用的 PDF 和图片文件存储在您的设备本地，不会上传至我们的服务器。保存的词汇数据存储在设备端的 SQLite 数据库中。您有责任确保拥有所导入内容的使用权。")
                        )

                        legalSection(
                            title: AppText.L("4. Subscriptions & Payments", "4. 구독 및 결제", "4. 订阅与付款"),
                            body: AppText.L(
                                """
                                The App offers free features and a premium subscription. Subscriptions are processed through the Apple App Store and are subject to Apple's payment terms. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. You can manage or cancel subscriptions in Settings > Apple ID > Subscriptions on your device.

                                Premium subscription includes:
                                • AI-powered contextual translation (meanings by part of speech)
                                • Synonym & antonym lookup
                                • Premium themes
                                """,
                                """
                                앱은 무료 기능과 프리미엄 구독 기능을 제공합니다. 구독은 Apple App Store를 통해 처리되며, Apple의 결제 약관이 적용됩니다. 구독은 현재 기간 종료 최소 24시간 전에 해지하지 않으면 자동 갱신됩니다. 구독 관리 및 해지는 기기의 설정 > Apple ID > 구독에서 가능합니다.

                                프리미엄 구독에는 다음 기능이 포함됩니다:
                                • AI 기반 문맥 번역 (품사별 뜻 제공)
                                • 동의어 · 반의어 조회
                                • 프리미엄 테마
                                """,
                                """
                                本应用提供免费功能和高级订阅。订阅通过 Apple App Store 处理，适用 Apple 的付款条款。除非在当前周期结束前至少24小时取消，否则订阅将自动续费。您可以在设备的"设置 > Apple ID > 订阅"中管理或取消订阅。

                                高级订阅包含以下功能：
                                • AI 语境翻译（按词性提供释义）
                                • 同义词和反义词查询
                                • 高级主题
                                """)
                        )

                        legalSection(
                            title: AppText.L("5. AI Services & External APIs", "5. AI 서비스 및 외부 API", "5. AI 服务与外部 API"),
                            body: AppText.L(
                                """
                                Premium features include AI-powered services, processed as follows:

                                • When you look up word translations or synonyms/antonyms, the queried word and a portion of the surrounding sentence (up to 80 characters) are sent to OpenAI's API via our server (Cloudflare Workers).
                                • Only the word, context sentence, and language settings are transmitted — no personally identifiable information (name, email, etc.) is sent.
                                • AI responses are cached to minimize repeated API calls for the same word.
                                • AI-generated translations and synonyms/antonyms are provided for reference and are not guaranteed to be fully accurate.
                                """,
                                """
                                프리미엄 기능은 AI 기반 서비스를 포함하며, 다음과 같이 처리됩니다:

                                • 단어 번역 및 동의어/반의어 조회 시, 조회한 단어와 해당 문장의 일부(최대 80자)가 당사 서버(Cloudflare Workers)를 경유하여 OpenAI API로 전송됩니다.
                                • 전송되는 데이터는 단어, 문맥 문장, 언어 설정에 한정되며, 개인 식별 정보(이름, 이메일 등)는 전송되지 않습니다.
                                • AI 응답은 캐싱되어 동일 단어의 반복 요청 시 외부 API 호출을 최소화합니다.
                                • AI가 생성한 번역 및 동의어/반의어는 참고용이며, 정확성을 완전히 보장하지 않습니다.
                                """,
                                """
                                高级功能包含 AI 驱动的服务，处理方式如下：

                                • 查询单词翻译或同义词/反义词时，查询的单词及周围句子的部分内容（最多80个字符）将通过我们的服务器（Cloudflare Workers）发送至 OpenAI 的 API。
                                • 仅传输单词、上下文句子和语言设置，不会发送任何个人身份信息（姓名、邮箱等）。
                                • AI 响应会被缓存，以减少对同一单词的重复 API 调用。
                                • AI 生成的翻译和同义词/反义词仅供参考，不保证完全准确。
                                """)
                        )

                        legalSection(
                            title: AppText.L("6. Intellectual Property", "6. 지적 재산권", "6. 知识产权"),
                            body: AppText.L(
                                "All intellectual property rights in the App's design, code, logos, and content belong to us. You may use the App for personal, non-commercial purposes only.",
                                "ReadTap 앱의 디자인, 코드, 로고 및 콘텐츠에 대한 모든 지적 재산권은 당사에 귀속됩니다. 사용자는 앱을 개인적, 비상업적 용도로만 사용할 수 있습니다.",
                                "本应用的设计、代码、标识和内容的所有知识产权归我们所有。您仅可将本应用用于个人非商业用途。")
                        )

                        legalSection(
                            title: AppText.L("7. Disclaimer", "7. 면책 조항", "7. 免责声明"),
                            body: AppText.L(
                                "The App is provided \"as is.\" We do not guarantee the accuracy of word definitions, translation quality, or OCR recognition rates. To the extent permitted by law, we are not liable for any direct or indirect damages arising from your use of the App.",
                                "앱은 \"있는 그대로\" 제공됩니다. 단어 뜻의 정확성, 번역 품질, OCR 인식률 등에 대해 완전한 보증을 하지 않습니다. 앱 사용으로 인한 직접적·간접적 손해에 대해 당사는 법률이 허용하는 범위 내에서 책임을 지지 않습니다.",
                                "本应用按「现状」提供。我们不保证单词释义的准确性、翻译质量或 OCR 识别率。在法律允许的范围内，我们不对因使用本应用而产生的任何直接或间接损害承担责任。")
                        )

                        legalSection(
                            title: AppText.L("8. Changes & Termination", "8. 서비스 변경 및 종료", "8. 变更与终止"),
                            body: AppText.L(
                                "We may modify the App's features or discontinue the service with prior notice. These Terms may be updated from time to time, and changes will be communicated within the App.",
                                "당사는 사전 통지를 통해 앱의 기능을 변경하거나 서비스를 종료할 수 있습니다. 본 약관은 수시로 업데이트될 수 있으며, 변경 시 앱 내에서 고지합니다.",
                                "我们可能会提前通知后修改应用功能或终止服务。本条款可能会不时更新，变更将在应用内通知。")
                        )

                        legalSection(
                            title: AppText.L("9. Governing Law", "9. 준거법", "9. 适用法律"),
                            body: AppText.L(
                                "These Terms are governed by the laws of the Republic of Korea. Any disputes shall be subject to the jurisdiction of courts in the Republic of Korea.",
                                "본 약관은 대한민국 법률에 따라 해석되며, 관련 분쟁은 대한민국 법원의 관할에 따릅니다.",
                                "本条款受大韩民国法律管辖。任何争议应由大韩民国法院管辖。")
                        )

                        legalSection(
                            title: AppText.L("10. Contact", "10. 문의", "10. 联系方式"),
                            body: AppText.L(
                                "For questions about these Terms, please contact us at:\n📧 arpof@arpof.com",
                                "본 약관에 대한 문의 사항은 아래 이메일로 연락해 주세요.\n📧 arpof@arpof.com",
                                "如对本条款有任何疑问，请通过以下邮箱联系我们：\n📧 arpof@arpof.com")
                        )

                        Text(AppText.L("Last updated: March 28, 2026", "최종 업데이트: 2026년 3월 28일", "最后更新：2026年3月28日"))
                            .font(.system(size: pad ? 13 : 11))
                            .foregroundStyle(mutedColor.opacity(0.6))
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, pad ? 32 : 24)
                    .padding(.vertical, pad ? 28 : 20)
                }
                .scrollIndicators(.hidden)
            .navigationTitle(AppText.L("Terms of Service", "이용약관", "服务条款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: pad ? 14 : 12, weight: .bold))
                            .foregroundStyle(mutedColor)
                    }
                }
            }
        }
    }

    private func legalSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: pad ? 10 : 8) {
            Text(title)
                .font(.system(size: pad ? 18 : 15, weight: .bold))
                .foregroundStyle(textColor)

            Text(body)
                .font(.system(size: pad ? 15 : 13))
                .foregroundStyle(textColor.opacity(0.82))
                .lineSpacing(pad ? 6 : 5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Privacy Policy

struct PrivacyPolicyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var pad: Bool { DSLayout.isPad }
    private var textColor: Color { colorScheme == .dark ? .white : Color(red: 0.12, green: 0.15, blue: 0.20) }
    private var mutedColor: Color { colorScheme == .dark ? Color.white.opacity(0.5) : Color(red: 0.12, green: 0.15, blue: 0.20).opacity(0.5) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: pad ? 24 : 18) {
                    legalSection(
                        title: AppText.L("1. Overview", "1. 개요", "1. 概述"),
                            body: AppText.L(
                                "ReadTap (the \"App\") values your privacy. This policy explains what information the App collects and how it is used.",
                                "ReadTap(이하 \"앱\")은 사용자의 개인정보 보호를 중요하게 생각합니다. 본 방침은 앱이 어떤 정보를 수집하고 어떻게 사용하는지 설명합니다.",
                                "ReadTap（以下简称「应用」）重视您的隐私。本政策说明应用收集哪些信息以及如何使用这些信息。")
                        )

                        legalSection(
                            title: AppText.L("2. Information We Collect", "2. 수집하는 정보", "2. 我们收集的信息"),
                            body: AppText.L(
                                """
                                The App processes the following information locally on your device:

                                • Vocabulary data: saved words, meanings, mastery state, example sentences
                                • Reading data: bookmarks, reading progress, last-read page
                                • Settings data: language, theme, reader preferences
                                • Streak data: daily reading and vocabulary learning records

                                When you sign in (optional):
                                • Email address and display name (via Supabase Authentication)

                                Data transmitted externally when using premium features:
                                • Queried word and a portion of the context sentence (up to 80 characters, for AI translation/synonym generation)
                                • Language settings (source/target language)

                                The App does not access sensitive information such as location, contacts, or photo library.
                                """,
                                """
                                앱은 다음 정보를 기기 내에서 로컬로 처리합니다:

                                • 어휘 데이터: 저장한 단어, 뜻, 암기 상태, 문장 예시
                                • 읽기 데이터: 북마크, 읽기 진행률, 마지막 읽은 페이지
                                • 설정 데이터: 언어, 테마, 리더 설정
                                • 스트릭 데이터: 일일 읽기 및 단어 학습 기록

                                계정 로그인 시 (선택 사항):
                                • 이메일 주소 및 표시 이름 (Supabase Authentication을 통해)

                                프리미엄 기능 사용 시 외부로 전송되는 정보:
                                • 조회한 단어 및 문장의 일부 (최대 80자, AI 번역/동의어 생성 목적)
                                • 언어 설정 (소스/타겟 언어)

                                앱은 위치 정보, 연락처, 사진 라이브러리 등 민감한 개인정보에 접근하지 않습니다.
                                """,
                                """
                                应用在您的设备上本地处理以下信息：

                                • 词汇数据：保存的单词、释义、掌握状态、例句
                                • 阅读数据：书签、阅读进度、上次阅读页
                                • 设置数据：语言、主题、阅读器偏好
                                • 连续学习数据：每日阅读和词汇学习记录

                                登录时（可选）：
                                • 电子邮箱和显示名称（通过 Supabase Authentication）

                                使用高级功能时外部传输的数据：
                                • 查询的单词和上下文句子的部分内容（最多80个字符，用于 AI 翻译/同义词生成）
                                • 语言设置（源语言/目标语言）

                                应用不会访问位置信息、通讯录、照片库等敏感个人信息。
                                """)
                        )

                        legalSection(
                            title: AppText.L("3. Where Data Is Stored", "3. 데이터 저장 위치", "3. 数据存储位置"),
                            body: AppText.L(
                                """
                                • All vocabulary, reading progress, and settings data are stored locally in an on-device SQLite database and UserDefaults.
                                • PDF and image files are stored in the App's Documents directory and are never transmitted to external servers.
                                • Account authentication is securely managed by Supabase Authentication.
                                """,
                                """
                                • 모든 어휘, 읽기 진행률, 설정 데이터는 기기 내 SQLite 데이터베이스 및 UserDefaults에 로컬로 저장됩니다.
                                • PDF 및 이미지 파일은 앱의 Documents 디렉토리에 저장되며 외부 서버로 전송되지 않습니다.
                                • 계정 인증 정보는 Supabase의 보안 인프라를 통해 안전하게 관리됩니다.
                                """,
                                """
                                • 所有词汇、阅读进度和设置数据均存储在设备端的 SQLite 数据库和 UserDefaults 中。
                                • PDF 和图片文件存储在应用的 Documents 目录中，不会传输至外部服务器。
                                • 账号认证信息由 Supabase 的安全基础设施安全管理。
                                """)
                        )

                        legalSection(
                            title: AppText.L("4. Third-Party Services", "4. 제3자 서비스", "4. 第三方服务"),
                            body: AppText.L(
                                """
                                The App uses the following third-party services:

                                • Supabase: User authentication. Supabase's privacy policy applies.
                                • Apple App Store: Subscription payment processing. Apple's privacy policy applies.
                                • Apple System Dictionary: Word definition lookup (processed on-device, no network transmission)
                                • OpenAI API (Premium): Contextual translation, part-of-speech meanings, and synonym/antonym generation. Only the queried word and a portion of the context sentence are transmitted — no personally identifiable information is included. OpenAI's privacy policy applies.
                                • Cloudflare Workers: API request relay and response caching. Cloudflare's privacy policy applies.
                                • Wiktionary (via Kaikki.org): English→Korean dictionary data used by the free-tier lookup. Content is included under the Creative Commons Attribution-ShareAlike 3.0 Unported license (CC BY-SA 3.0).

                                The App does not use advertising SDKs or analytics tools for tracking user behavior.
                                """,
                                """
                                앱은 다음 제3자 서비스를 사용합니다:

                                • Supabase: 사용자 인증. Supabase의 개인정보 처리방침이 적용됩니다.
                                • Apple App Store: 구독 결제 처리. Apple의 개인정보 처리방침이 적용됩니다.
                                • Apple 시스템 사전: 단어 뜻 조회 (기기 내 처리, 네트워크 전송 없음)
                                • OpenAI API (프리미엄): 문맥 번역, 품사별 뜻, 동의어/반의어 생성. 조회한 단어와 문장 일부만 전송되며, 개인 식별 정보는 포함되지 않습니다. OpenAI의 개인정보 처리방침이 적용됩니다.
                                • Cloudflare Workers: API 요청 중계 및 응답 캐싱 처리. Cloudflare의 개인정보 처리방침이 적용됩니다.
                                • Wiktionary (Kaikki.org 경유): 무료 플랜 사전 조회에 사용되는 영어→한국어 사전 데이터. Creative Commons Attribution-ShareAlike 3.0 Unported 라이선스(CC BY-SA 3.0)로 포함됩니다.

                                앱은 광고 SDK를 사용하지 않으며, 사용자 행동 추적을 위한 분석 도구를 사용하지 않습니다.
                                """,
                                """
                                应用使用以下第三方服务：

                                • Supabase：用户认证。适用 Supabase 隐私政策。
                                • Apple App Store：订阅支付处理。适用 Apple 隐私政策。
                                • Apple 系统词典：单词释义查询（设备端处理，无网络传输）
                                • OpenAI API（高级版）：语境翻译、词性释义和同义词/反义词生成。仅传输查询的单词和上下文句子的部分内容，不包含任何个人身份信息。适用 OpenAI 隐私政策。
                                • Cloudflare Workers：API 请求中继和响应缓存处理。适用 Cloudflare 隐私政策。
                                • Wiktionary（通过 Kaikki.org）：免费版词典查询使用的英韩词典数据。依据 Creative Commons Attribution-ShareAlike 3.0 Unported 许可（CC BY-SA 3.0）包含。

                                应用不使用广告 SDK，也不使用用户行为追踪分析工具。
                                """)
                        )

                        legalSection(
                            title: AppText.L("5. Data Sharing", "5. 데이터 공유", "5. 数据共享"),
                            body: AppText.L(
                                "We do not sell, rent, or share your personal data with third parties. User data will not be disclosed externally except as required by law.",
                                "당사는 사용자의 개인 데이터를 제3자에게 판매, 임대 또는 공유하지 않습니다. 법률에 의해 요구되는 경우를 제외하고, 사용자 데이터는 외부에 공개되지 않습니다.",
                                "我们不会向第三方出售、出租或共享您的个人数据。除法律要求外，用户数据不会对外公开。")
                        )

                        legalSection(
                            title: AppText.L("6. Children's Privacy", "6. 아동 개인정보 보호", "6. 儿童隐私保护"),
                            body: AppText.L(
                                "The App does not knowingly collect personal information from children under 13. If we become aware that information has been collected from a user under 13, we will promptly delete it.",
                                "앱은 만 13세 미만 아동의 개인정보를 의도적으로 수집하지 않습니다. 만 13세 미만 사용자의 정보가 수집된 사실을 인지하게 되면 즉시 해당 정보를 삭제합니다.",
                                "本应用不会故意收集13岁以下儿童的个人信息。如果我们发现收集了13岁以下用户的信息，将立即删除。")
                        )

                        legalSection(
                            title: AppText.L("7. Your Rights", "7. 사용자 권리", "7. 您的权利"),
                            body: AppText.L(
                                """
                                You have the following rights:

                                • Data deletion: You can delete saved words individually or in bulk within the App. Uninstalling the App completely removes all local data.
                                • Account deletion: If signed in, you can request account deletion.
                                • Data access: Since all data is stored locally on your device, you have direct access to and control over your data.
                                """,
                                """
                                사용자는 다음 권리를 가집니다:

                                • 데이터 삭제: 앱 내에서 저장된 단어를 개별 또는 일괄 삭제할 수 있습니다. 앱을 삭제하면 모든 로컬 데이터가 완전히 제거됩니다.
                                • 계정 삭제: 로그인한 경우, 계정 삭제를 요청할 수 있습니다.
                                • 데이터 접근: 모든 데이터가 기기에 로컬로 저장되므로, 사용자가 직접 데이터에 접근하고 관리할 수 있습니다.
                                """,
                                """
                                您拥有以下权利：

                                • 数据删除：您可以在应用内单独或批量删除已保存的单词。卸载应用将完全移除所有本地数据。
                                • 账户删除：如已登录，您可以申请删除账户。
                                • 数据访问：所有数据均存储在您的设备本地，您可以直接访问和管理您的数据。
                                """)
                        )

                        legalSection(
                            title: AppText.L("8. Security", "8. 보안", "8. 安全"),
                            body: AppText.L(
                                "The App relies on iOS device security features (data encryption, app sandboxing) to protect your data. Authentication data is managed through Supabase's security infrastructure.",
                                "앱은 iOS 기기의 기본 보안 기능(데이터 암호화, 앱 샌드박싱)에 의존하여 사용자 데이터를 보호합니다. 인증 데이터는 Supabase의 보안 인프라를 통해 관리됩니다.",
                                "本应用依赖iOS设备安全功能（数据加密、应用沙盒）来保护您的数据。认证数据通过Supabase的安全基础设施管理。")
                        )

                        legalSection(
                            title: AppText.L("9. Policy Changes", "9. 방침 변경", "9. 政策变更"),
                            body: AppText.L(
                                "This Privacy Policy may be updated from time to time. Significant changes will be communicated within the App.",
                                "본 개인정보 보호 방침은 수시로 업데이트될 수 있습니다. 중요한 변경 사항이 있을 경우 앱 내에서 고지합니다.",
                                "本隐私政策可能会不时更新。如有重大变更，将在应用内通知。")
                        )

                        legalSection(
                            title: AppText.L("10. Contact", "10. 문의", "10. 联系我们"),
                            body: AppText.L(
                                "For privacy-related inquiries, please contact us at:\n📧 arpof@arpof.com",
                                "개인정보 보호와 관련된 문의 사항은 아래 이메일로 연락해 주세요.\n📧 arpof@arpof.com",
                                "如有隐私相关问题，请通过以下邮箱联系我们：\n📧 arpof@arpof.com")
                        )

                    Text(AppText.L("Last updated: March 28, 2026", "최종 업데이트: 2026년 3월 28일", "最后更新：2026年3月28日"))
                        .font(.system(size: pad ? 13 : 11))
                        .foregroundStyle(mutedColor.opacity(0.6))
                        .padding(.top, 8)
                }
                .padding(.horizontal, pad ? 32 : 24)
                .padding(.vertical, pad ? 28 : 20)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(AppText.L("Privacy Policy", "개인정보 보호 방침", "隐私政策"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: pad ? 14 : 12, weight: .bold))
                            .foregroundStyle(mutedColor)
                    }
                }
            }
        }
    }

    private func legalSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: pad ? 10 : 8) {
            Text(title)
                .font(.system(size: pad ? 18 : 15, weight: .bold))
                .foregroundStyle(textColor)

            Text(body)
                .font(.system(size: pad ? 15 : 13))
                .foregroundStyle(textColor.opacity(0.82))
                .lineSpacing(pad ? 6 : 5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
