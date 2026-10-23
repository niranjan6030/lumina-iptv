import SwiftUI
import UserNotifications
import LuminaCore

enum AppTab: Hashable { case live, library, search, settings }

struct PINRequest: Identifiable {
    let id = UUID()
    let group: String
    let onSuccess: () -> Void
}

/// Phone-UI-only state (the CarPlay scene never touches this).
@MainActor @Observable
final class UIState {
    static let shared = UIState()
    var showPlayer = false
    var tab: AppTab = .live
    var pinRequest: PINRequest?
    var presentedChannelForSchedule: Channel?

    func play(_ channel: Channel, in list: [Channel]? = nil) {
        if AppModel.shared.isLocked(group: channel.group) {
            pinRequest = PINRequest(group: channel.group) { [weak self] in self?.play(channel, in: list) }
            return
        }
        PlayerController.shared.setAudioOnly(false)
        PlayerController.shared.play(channel, in: list)
        showPlayer = true
    }

    func play(_ item: PlayableVOD, queue: [PlayableVOD] = [], resumeAt: TimeInterval = 0) {
        PlayerController.shared.setAudioOnly(false)
        PlayerController.shared.play(item, queue: queue, resumeAt: resumeAt)
        showPlayer = true
    }
}

@main
struct LuminaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    await model.bootstrap()
                    #if DEBUG
                    await DebugLaunch.run(model)
                    #endif
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in PlayerController.shared.configureIfNeeded() }
        return true
    }

    // Show reminders even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tapping a reminder jumps straight to the channel.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["channelID"] as? String else { return }
        await AppModel.shared.bootstrap()
        await MainActor.run {
            if let ch = AppModel.shared.channel(id: id) { UIState.shared.play(ch) }
        }
    }
}

enum ReminderCenter {
    static func schedule(_ r: Reminder) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let lead: TimeInterval = 120
        let delay = max(1, r.start.timeIntervalSinceNow - lead)
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = "Starts soon on \(r.channelName)"
        content.sound = .default
        content.userInfo = ["channelID": r.channelID]
        let req = UNNotificationRequest(
            identifier: r.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do { try await center.add(req); return true } catch { return false }
    }

    static func cancel(_ r: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [r.id])
    }
}

#if DEBUG
/// Debug-only launch switches used by CI to screenshot the app: --demo, --tab=<library|search|settings>, --play-first
enum DebugLaunch {
    @MainActor static func run(_ model: AppModel) async {
        let args = CommandLine.arguments
        if args.contains("--demo") { await model.addDemo() }
        if let t = args.first(where: { $0.hasPrefix("--tab=") })?.dropFirst(6) {
            switch t {
            case "library": UIState.shared.tab = .library
            case "search": UIState.shared.tab = .search
            case "settings": UIState.shared.tab = .settings
            default: break
            }
        }
        if args.contains("--play-first"), let ch = model.visibleChannels.first {
            UIState.shared.play(ch, in: model.visibleChannels)
        }
    }
}
#endif
