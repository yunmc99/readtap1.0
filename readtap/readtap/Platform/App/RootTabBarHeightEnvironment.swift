import SwiftUI

private struct RootTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var rootTabBarHeight: CGFloat {
        get { self[RootTabBarHeightKey.self] }
        set { self[RootTabBarHeightKey.self] = newValue }
    }
}
