// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

#if canImport(Dispatch)
import Dispatch
#endif

/// Independent rows use the host's worker pool where available. A browser worker runs the
/// same rows serially; it has no libdispatch and does not share engine state with the UI.
enum ParallelWork {
    static func forEach(iterations: Int, execute: (Int) -> Void) {
        #if canImport(Dispatch)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: execute)
        #else
        for index in 0..<iterations { execute(index) }
        #endif
    }
}
