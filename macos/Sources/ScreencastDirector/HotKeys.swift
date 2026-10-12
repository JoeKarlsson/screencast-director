import Carbon.HIToolbox

/// ⌃⌥⌘R starts and stops a recording from any app. RegisterEventHotKey needs no Accessibility
/// permission. (Followspot uses ⌃⌥R, so this adds ⌘ to stay clear of it.)
final class HotKeys {
  var onToggle: (() -> Void)?
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func register() {
    guard ref == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        let me = Unmanaged<HotKeys>.fromOpaque(context!).takeUnretainedValue()
        me.onToggle?()
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    let id = EventHotKeyID(signature: OSType(0x5343_4452), id: 1)  // 'SCDR'
    RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
  }
}
