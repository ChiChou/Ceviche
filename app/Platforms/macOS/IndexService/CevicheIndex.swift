import Foundation
import CevicheCore

@main
struct CevicheIndex {
    static func main() {
        let delegate = CatalogIndexServiceDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        withExtendedLifetime(delegate) { listener.resume() }
    }
}
