import SwiftUI
import StoreKit
import CevicheCore

/// Ceviche Pro: a one-time App Store purchase (a non-consumable) whose only effect is removing the Unpaid badge. Every
/// feature, iCloud sync included, is the same with or without it.
///
/// **Identity stays out of the repository.** The product ID comes from `CEVICHE_STORE_PRODUCTS` in the git-ignored
/// build.config (or the environment) and reaches the app through `CevicheStoreProducts` in the built Info.plist, next to
/// the Team ID, bundle ID, iCloud container and signing identity that already come from there. None of these is a
/// secret: the bundle ID, container and product ID are readable in any shipped copy, and the Team ID is in its code
/// signature. They are kept out only so a fork does not build as us. The real secrets, App Store Connect API keys
/// (.p8), the App Store server shared secret and signing private keys, are never needed by the client and never go in
/// build.config, the repository or the app. The price is set on the product in App Store Connect, not here.
///
/// **A fork builds a community build by default** (`CEVICHE_DISTRIBUTION=community`): the store is compiled out, so
/// there is no badge and no menu item. Only `CEVICHE_DISTRIBUTION=appstore` reads the product ID.
///
/// **Ownership is StoreKit 2 on the device.** `Transaction.currentEntitlements` lists what this Apple Account owns;
/// StoreKit verifies each transaction's JWS signature against Apple's chain, and an unverified or refunded one never
/// counts. `Transaction.updates` delivers purchases made on another device, refunds and Family Sharing changes while
/// the app runs. StoreKit keeps its own signed cache, so this works offline and there is no flag of ours in
/// UserDefaults. There is no server and no receipt secret. Test with a sandbox Apple Account in a development-signed
/// build: a SwiftPM executable is not an Xcode app target, so a `.storekit` file cannot be attached to its run.
///
/// **What this does not stop.** Anyone can delete the badge and build the app themselves; the source is Apache-2.0 and
/// that is their right. Nothing is locked, so there is nothing else to protect.
@MainActor
final class Pro: ObservableObject {
    enum Access: Equatable {
        /// No product ID in this build: nothing to sell.
        case community
        /// Waiting for StoreKit's first answer after launch; no badge shows meanwhile.
        case checking
        case purchased
        case unpaid
    }
    /// One verified transaction from `Transaction.currentEntitlements`, reduced to what decides ownership.
    struct Entitlement: Equatable {
        var productID: String
        var revoked = false
    }
    /// Replaced only by tests, before any view reads it.
    static var shared = Pro(productIDs: BuildFeatures.storeProducts)
    static let windowID = "pro"
    let productIDs: [String]
    @Published private(set) var access: Access
    private var updates: Task<Void, Never>?

    /// `access` stands in for StoreKit's answer in tests; `start` replaces it.
    init(productIDs: [String], access: Access? = nil) {
        self.productIDs = productIDs
        self.access = productIDs.isEmpty ? .community : access ?? .checking
    }
    var sells: Bool { access != .community }
    var showsBadge: Bool { access == .unpaid }

    /// Purchased when this Apple Account owns any of this build's products and Apple has not refunded it.
    nonisolated static func access(productIDs: Set<String>, entitlements: [Entitlement]) -> Access {
        guard !productIDs.isEmpty else { return .community }
        return entitlements.contains { productIDs.contains($0.productID) && !$0.revoked } ? .purchased : .unpaid
    }

    /// At launch: reads what this account owns and listens for changes for the life of the app.
    func start() {
        guard !productIDs.isEmpty, updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }
    func refresh() async {
        guard !productIDs.isEmpty else { return }
        var entitlements: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            entitlements.append(Entitlement(productID: transaction.productID, revoked: transaction.revocationDate != nil))
        }
        access = Self.access(productIDs: Set(productIDs), entitlements: entitlements)
    }
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}

/// The title bar's Unpaid badge; a click opens Ceviche Pro.
struct UnpaidBadge: View {
    @ObservedObject var pro = Pro.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if pro.showsBadge {
            Button { openWindow(id: Pro.windowID) } label: {
                Text(L10n.tr("Unpaid")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.ink.opacity(0.06), in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).help(L10n.tr("Buy Ceviche Pro…"))
        }
    }
}

/// Ceviche ▸ Buy Ceviche Pro…: the product as App Store Connect describes and prices it, and Restore Purchases.
struct ProView: View {
    @ObservedObject var pro = Pro.shared
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Ceviche Pro").font(.title2.weight(.semibold))
            if pro.access == .purchased {
                Label(L10n.tr("Purchased"), systemImage: "checkmark.seal").font(.callout)
            } else {
                Text(L10n.tr("Every feature stays free. Pro removes the badge.")).font(.callout).foregroundStyle(.secondary)
                ForEach(pro.productIDs, id: \.self) { id in
                    ProductView(id: id).productViewStyle(.compact)
                }
                Button(L10n.tr("Restore Purchases")) { Task { await pro.restore() } }.buttonStyle(.textLink)
            }
        }
        .onInAppPurchaseCompletion { _, _ in await pro.refresh() }
        .padding(28).frame(width: 360)
    }
}

/// The app menu's Pro items; nothing in a community build or once purchased.
struct ProMenuItems: View {
    @ObservedObject var pro = Pro.shared
    let openWindow: OpenWindowAction
    var body: some View {
        if pro.sells, pro.access != .purchased {
            Button(L10n.tr("Buy Ceviche Pro…")) { openWindow(id: Pro.windowID) }
        }
    }
}
