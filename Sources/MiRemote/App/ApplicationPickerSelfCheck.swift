import AppKit
import Foundation

func applicationPickerSelfCheck(expect: (Bool, String, String) -> Void) {
    expect(profileFallbackName("com.openai.chat") == "ChatGPT 桌面版"
           && profileFallbackName("org.videolan.vlc") == "VLC 播放器"
           && profileFallbackName("us.zoom.xos") == "Zoom 会议",
           "未安装 App 使用内置预设名称", "")
    expect(profileFallbackName("com.example.custom") == "com.example.custom",
           "未知自定义 App 保留包名", "")
    expect(ATVVDiscoveryRetrySelfCheck.run(), "语音发现重试与取消回归", "")
    let bageshuo = URL(fileURLWithPath: "/Applications/网易叭哥说.app")
    let helper = URL(fileURLWithPath: "/Applications/网易叭哥说.app/Contents/Frameworks/WebKit Helper.app")
    expect(shouldListRunningApplication(bundleIdentifier: "com.bageshuo",
                                        bundleURL: bageshuo,
                                        activationPolicy: .accessory,
                                        ownBundleIdentifier: "com.remokey.controller"),
           "App 选择器显示顶层 accessory 应用", "")
    expect(shouldListRunningApplication(bundleIdentifier: "com.apple.Safari",
                                        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                                        activationPolicy: .regular,
                                        ownBundleIdentifier: "com.remokey.controller"),
           "App 选择器保留普通应用", "")
    expect(!shouldListRunningApplication(bundleIdentifier: "com.bageshuo.helper",
                                         bundleURL: helper,
                                         activationPolicy: .accessory,
                                         ownBundleIdentifier: "com.remokey.controller"),
           "App 选择器排除嵌套辅助进程", "")
    expect(!shouldListRunningApplication(bundleIdentifier: "com.remokey.controller",
                                         bundleURL: URL(fileURLWithPath: "/Applications/RemoKey.app"),
                                         activationPolicy: .regular,
                                         ownBundleIdentifier: "com.remokey.controller")
           && !shouldListRunningApplication(bundleIdentifier: nil,
                                            bundleURL: bageshuo,
                                            activationPolicy: .accessory,
                                            ownBundleIdentifier: "com.remokey.controller"),
           "App 选择器排除自身和无 Bundle ID 进程", "")
}
