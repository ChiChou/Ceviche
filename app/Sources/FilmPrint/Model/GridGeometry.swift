// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

/// How the spatial stages lay their grids, shared by the plan (which prices a tile's apron by it) and the renderer.
enum GridGeometry {
    /// Sigma of the Gaussian that three passes of a box of `radius` approximate.
    static func boxSigma(_ radius: Int32) -> Float { let width = Float(2 * radius + 1); return ((width * width - 1) * 0.25).squareRoot() }

    /// The stride one halation scale is box-averaged by: the largest power of two, up to 8, that keeps the grid's
    /// sigma above 2.5 cells, so averaging down and reading back add little to the blur itself.
    static func halationStride(_ radius: Int32) -> Int32 {
        let sigma = boxSigma(radius)
        var stride: Int32 = 1
        while stride < 8 && Float(2 * stride) * 2.5 <= sigma { stride *= 2 }
        return stride
    }

    /// The box radius on a grid of `stride` whose three passes, with the spread the averaging and the read back
    /// add, carry the full-resolution chain's sigma.
    static func halationStridedRadius(_ radius: Int32, _ stride: Int32) -> Int32 {
        if stride <= 1 { return radius }
        let sigma = boxSigma(radius)
        let variance = max(sigma * sigma / Float(stride * stride) - 0.25, 0.25)
        return max(Int32(((4 * variance + 1).squareRoot() - 1) * 0.5 + 0.5), 1)
    }

    /// The stride a diffusing field of this sigma blurs on.
    static func fieldStride(_ sigma: Float) -> Int32 { sigma >= 8 ? 8 : sigma >= 4 ? 4 : sigma >= 2 ? 2 : 1 }

    /// How far a field's blur of `sigma` (`radius` taps at full resolution) really reads: its radius on the grid,
    /// the cell it lands in and the neighbor it is read back through all stand outside the nominal radius.
    static func gaussianReach(_ sigma: Float, _ radius: Int32) -> Int32 {
        if radius <= 0 { return 0 }
        let stride = fieldStride(sigma)
        let gridRadius = max((radius + stride - 1) / stride, 1)
        return stride == 1 ? radius + 1 : stride * (gridRadius + 2)
    }
}
