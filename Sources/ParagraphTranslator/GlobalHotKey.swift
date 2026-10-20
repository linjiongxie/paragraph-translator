import Carbon
import Foundation

enum GlobalHotKeyError: LocalizedError {
    case shortcutInUse
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .shortcutInUse:
            return "快捷键 ⌥⌘T 已被其他功能占用。请关闭占用该快捷键的应用或更改其快捷键后，重新启动段落翻译。"
        case .registrationFailed(let status):
            return "无法注册快捷键 ⌥⌘T（系统错误 \(status)）。请重新启动段落翻译后再试。"
        }
    }
}

@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x5054_524E // PTRN
    private static let identifier: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) throws {
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard status == noErr,
                      identifier.signature == GlobalHotKey.signature,
                      identifier.id == GlobalHotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers this application event on the main thread.
                // Execute synchronously so the source selection is captured
                // before any later UI activation changes its focus.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().onTrigger()
                }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed(handlerStatus)
        }

        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T), UInt32(optionKey | cmdKey),
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard registrationStatus == noErr else {
            unregister()
            if registrationStatus == eventHotKeyExistsErr {
                throw GlobalHotKeyError.shortcutInUse
            }
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
