// The app the StoreKit tests run inside. StoreKit Testing only answers a test
// hosted in an app, and this one shows nothing: no window and no Dock icon (an agent app), so a
// run never takes the screen.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
