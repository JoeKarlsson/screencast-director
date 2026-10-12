import Carbon.HIToolbox

/// Global shortcuts that work from any app. RegisterEventHotKey needs no Accessibility permission.
/// ⌃⌥⌘R starts and stops a recording; ⌃⌥⌘M marks a retake (the line you just said gets cut, the
/// redo stays). Followspot uses ⌃⌥ alone, so these add ⌘ to stay clear of it.
final class HotKeys {
  var onToggle: (() -> Void)?
  var onRetake: (() -> Void)?
  private var refs: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?

  func register() {
    guard refs.isEmpty else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        let me = Unmanaged<HotKeys>.fromOpaque(context!).takeUnretainedValue()
        if id.id == 1 { me.onToggle?() } else if id.id == 2 { me.onRetake?() }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    for (i, key) in [kVK_ANSI_R, kVK_ANSI_M].enumerated() {
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x5343_4452), id: UInt32(i + 1))  // 'SCDR'
      RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
      if let ref { refs.append(ref) }
    }
  }
}
