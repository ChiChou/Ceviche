/// Keeps a large, rarely set optional value out of line: one pointer in the enclosing struct instead of the value itself.
///
/// `Adjustments` is copied by value through every edit, render and import, often on Swift concurrency threads whose
/// stacks are small. Image decoders called from those threads (RawCamera, for a thumbnail) recurse deeply, so each
/// kilobyte of edit carried in the frames above them brings a stack overflow closer. Value semantics and equality by
/// content are unchanged; the saved format too, since `Adjustments` codes the wrapped values itself.
@propertyWrapper
public struct Boxed<Wrapped: Equatable & Sendable>: Equatable, Sendable {
    /// `indirect` puts the payload in a heap box, which is shared until a copy is changed.
    private indirect enum Storage: Equatable, Sendable { case value(Wrapped) }
    private var storage: Storage?

    public init() {}
    public init(wrappedValue: Wrapped?) { storage = wrappedValue.map(Storage.value) }

    public var wrappedValue: Wrapped? {
        get { if case .value(let value)? = storage { value } else { nil } }
        set { storage = newValue.map(Storage.value) }
    }
}
