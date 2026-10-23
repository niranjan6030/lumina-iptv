import os, re, sys, glob
root, w = sys.argv[1], sys.argv[2]

SHIM = r'''
import SwiftUI
import AVFoundation
import AVKit
import AppKit

typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIView = NSView
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

actor ImageLoader {
    static let shared = ImageLoader()
    func image(_ url: URL, maxPixel: CGFloat) async -> NSImage? { nil }
}
final class AVAudioSession {
    static let shared_ = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared_ }
    struct Category: RawRepresentable { var rawValue: String; static let playback = Category(rawValue: "p") }
    struct Mode: RawRepresentable { var rawValue: String; static let moviePlayback = Mode(rawValue: "m") }
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    struct InterruptionOptions: OptionSet { let rawValue: UInt; static let shouldResume = InterruptionOptions(rawValue: 1) }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2, unknown = 0 }
    static let interruptionNotification = Notification.Name("i")
    static let routeChangeNotification = Notification.Name("r")
    func setCategory(_ c: Category, mode: Mode) throws {}
    func setActive(_ a: Bool) throws {}
}
let AVAudioSessionInterruptionTypeKey = "t"
let AVAudioSessionInterruptionOptionKey = "o"
let AVAudioSessionRouteChangeReasonKey = "rr"

final class ShimApp { static let shared = ShimApp(); var isIdleTimerDisabled = false }
typealias UIApplication = ShimApp

enum ShimTitleMode { case inline, large }
enum ShimKeyboard { case URL, numberPad, `default` }
enum ShimCap { case never, words }
extension View {
    func navigationBarTitleDisplayMode(_ m: ShimTitleMode) -> some View { self }
    func keyboardType(_ k: ShimKeyboard) -> some View { self }
    func textInputAutocapitalization(_ c: ShimCap?) -> some View { self }
    func fullScreenCover<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View { sheet(isPresented: isPresented, content: content) }
    func statusBarHidden(_ h: Bool) -> some View { self }
}
extension ToolbarItemPlacement { static var topBarTrailing: ToolbarItemPlacement { .automatic } }
extension ListStyle where Self == InsetListStyle { static var insetGrouped: InsetListStyle { .inset } }

protocol ShimRepresentable: View {}
struct ShimContext {}
'''

def read(p): return open(os.path.join(root, p)).read()

out = {}
out['Shim.swift'] = SHIM

# Plain files: used as-is.
for p in ['App/Model/Persistence.swift', 'App/Model/AppModel.swift', 'App/UI/Theme.swift', 'App/UI/RootView.swift',
          'App/UI/Live/LiveView.swift', 'App/UI/Library/LibraryView.swift', 'App/CarPlay/__skip__']:
    f = os.path.join(root, p)
    if os.path.exists(f): out[os.path.basename(p)] = open(f).read()

# PlayerController: swap UIKit import.
out['PlayerController.swift'] = read('App/Model/PlayerController.swift').replace('import UIKit', 'import AppKit')

# LuminaApp: keep everything up to @main (UIState, PINRequest, AppTab) + ReminderCenter, drop the App/AppDelegate.
la = read('App/LuminaApp.swift')
head = la[:la.index('@main')]
rc = la[la.index('enum ReminderCenter'):]
out['LuminaAppParts.swift'] = head + rc

# SettingsView: replace ShareSheet (UIKit).
sv = read('App/UI/Settings/SettingsView.swift')
i = sv.index('struct ShareSheet'); j = sv.index('// MARK: - Source detail')
sv = sv[:i] + 'struct ShareSheet: View { let url: URL; var body: some View { Text(url.absoluteString) } }\n\n' + sv[j:]
out['SettingsView.swift'] = sv

# PlayerScreen: replace UIKit-backed pieces with stubs.
ps = read('App/UI/Player/PlayerScreen.swift')
i = ps.index('// MARK: - Persistent video surface'); j = ps.index('// MARK: - Screen')
stub = '''
@MainActor @Observable final class PiPController {
    static let shared = PiPController()
    var isActive = false
    var isPossible = true
    var gravity: AVLayerVideoGravity = .resizeAspect
    func toggle() {}
}
struct VideoSurface: View { var body: some View { Color.black } }
struct AirPlayButton: View { var body: some View { Color.clear } }
'''
out['PlayerScreen.swift'] = ps[:i] + stub + ps[j:]

# CarPlay can't be checked on macOS (no CarPlay framework).

for name, text in out.items():
    open(os.path.join(w, name), 'w').write(text)
