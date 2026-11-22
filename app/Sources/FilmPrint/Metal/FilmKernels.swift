// The stages these kernels compute follow their definitions in the Fotufilm engine's Halide pipeline
// (https://github.com/DhaliwalX/fotufilm-engine, Sources/FotufilmHalide/Stages and Graph; Copyright 2026 MUAStudio Inc.,
// Apache License, Version 2.0), written anew in Metal with Ceviche's own tiling.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

/// The film's image formation as Metal compute kernels: exposure through the spectral cube, the emulsion's spread,
/// halation, the development with its couplers and adjacency, grain, and the print through the film and paper cubes.
/// Every kernel reads the development's packed configuration (`Slot`) and works on one tile of the frame, which carries
/// its own apron; coordinates that the picture depends on (grain, the regional tone grid, the halation grids) are the
/// frame's, so a tile develops as the part of the whole frame it is.
enum FilmKernels {
    /// Samples in the tabulated characteristic curves: the film's (and a donor layer's) finely enough that reading
    /// them stands for the curve itself, the paper's as the print has always been read.
    static let filmCurveSamples = 16384, paperCurveSamples = 2048
    static let curveMin: Float = -8, curveMax: Float = 8
    static let lutDimension = 33

    static let source = Slot.metalDefinitions + """
    #define FILM_CURVE_SAMPLES \(filmCurveSamples)
    #define PAPER_CURVE_SAMPLES \(paperCurveSamples)
    #define CURVE_MIN \(curveMin)f
    #define CURVE_MAX \(curveMax)f
    #define LUT_N \(lutDimension)
    #define F_MTF \(FilmFeature.mtf)u
    #define F_HALATION \(FilmFeature.halation)u
    #define F_COUPLERS \(FilmFeature.couplers)u
    #define F_ADJACENCY \(FilmFeature.adjacency)u
    #define F_GRAIN \(FilmFeature.grain)u
    #define F_REVERSAL \(FilmFeature.reversal)u
    #define F_MONOCHROME \(FilmFeature.monochrome)u
    #define F_MTF_LUMA \(FilmFeature.mtfLuma)u
    #define F_COUPLER_DIFFUSION \(FilmFeature.couplerDiffusion)u
    #define F_DENSITY_IN \(FilmFeature.densityIn)u
    #define F_PRINT_DETAIL \(FilmFeature.printDetail)u
    #define F_GRAIN_MOTTLE \(FilmFeature.grainMottle)u
    #define F_PRINT_MTF \(FilmFeature.printMTF)u
    #define F_DONOR_LAYER \(FilmFeature.donorLayer)u
    """ + #"""

    #include <metal_stdlib>
    using namespace metal;

    typedef const device float *Config;
    typedef const device float4 *Table;

    // One tile of a frame. Field indices: 0 couplers, 1 chromatic fringe, 2 adjacency, 3 adjacency's second scale.
    struct Tile {
        int width, height;          // the tile with its apron
        int originX, originY;       // where its first pixel sits in the frame
        uint features, seed;
        int halationStride[3], halationWidth[3], halationHeight[3];
        int fieldStride[4], fieldPhaseX[4], fieldPhaseY[4], fieldWidth[4], fieldHeight[4];
        int fringeRadius;
        float grainLambda, mottleLambda;
        float sceneMatrix[9];       // the scene's RGB to linear Rec. 2020, by rows
        float pictureMatrix[9];     // the print's linear Display P3 to the picture's RGB
    };

    static inline float3 transformed(constant float *m, float3 v) {
        return float3(m[0] * v.r + m[1] * v.g + m[2] * v.b, m[3] * v.r + m[4] * v.g + m[5] * v.b, m[6] * v.r + m[7] * v.g + m[8] * v.b);
    }

    // MARK: Curves and cubes

    static inline float softplus(float v) { return v > 20.0f ? v : (v < -20.0f ? exp(v) : log(1.0f + exp(v))); }
    static inline float smooth01(float t) { t = clamp(t, 0.0f, 1.0f); return t * t * (3.0f - 2.0f * t); }

    // A tabulated curve read at log exposure x: four curves a texel.
    static inline float4 curveAt(Table table, int samples, float x) {
        float q = clamp((x - CURVE_MIN) * (float(samples - 1) / (CURVE_MAX - CURVE_MIN)), 0.0f, float(samples - 1));
        int index = min(int(q), samples - 2);
        float4 low = table[index];
        return low + (q - float(index)) * (table[index + 1] - low);
    }
    static inline float3 filmCurve(Table curves, float3 x) {
        return float3(curveAt(curves, FILM_CURVE_SAMPLES, x.x).x, curveAt(curves, FILM_CURVE_SAMPLES, x.y).y, curveAt(curves, FILM_CURVE_SAMPLES, x.z).z);
    }
    static inline float3 paperCurve(Table curves, float3 x) {
        return float3(curveAt(curves, PAPER_CURVE_SAMPLES, x.x).x, curveAt(curves, PAPER_CURVE_SAMPLES, x.y).y, curveAt(curves, PAPER_CURVE_SAMPLES, x.z).z);
    }
    // dMax - dMin of a six-parameter curve, and of a film record with its second population.
    static inline float curveRange(Config cfg, int base) { return cfg[base + 1] * (cfg[base + 4] - cfg[base + 2]); }
    static inline float filmRange(Config cfg, int c) {
        int second = S_CURVE_SECONDARY + c * 5;
        return curveRange(cfg, S_CURVES + c * 6) + cfg[second] * (cfg[second + 3] - cfg[second + 1]);
    }
    static inline float3 filmBase(Config cfg) { return float3(cfg[S_CURVES], cfg[S_CURVES + 6], cfg[S_CURVES + 12]); }
    static inline float3 filmRanges(Config cfg) { return float3(filmRange(cfg, 0), filmRange(cfg, 1), filmRange(cfg, 2)); }

    // Tetrahedral interpolation in a 33-node cube.
    static inline float4 cube(Table lut, float3 p) {
        float3 q = clamp(p, 0.0f, 1.0f) * float(LUT_N - 1);
        int3 i = min(int3(q), int3(LUT_N - 2));
        float3 f = q - float3(i);
        float largest = max(f.x, max(f.y, f.z)), smallest = min(f.x, min(f.y, f.z));
        float middle = max(min(f.x, f.y), min(max(f.x, f.y), f.z));
        bool xl = f.x >= f.y && f.x >= f.z, yl = !xl && f.y >= f.z;
        bool xs = f.x <= f.y && f.x <= f.z, ys = !xs && f.y <= f.z;
        int3 a = int3(xl ? 1 : 0, yl ? 1 : 0, (!xl && !yl) ? 1 : 0);
        int3 b = int3(xs ? 0 : 1, ys ? 0 : 1, (!xs && !ys) ? 0 : 1);
        int base = (i.z * LUT_N + i.y) * LUT_N + i.x;
        float4 c000 = lut[base];
        float4 near = lut[base + (a.z * LUT_N + a.y) * LUT_N + a.x];
        float4 far = lut[base + (b.z * LUT_N + b.y) * LUT_N + b.x];
        float4 c111 = lut[base + (LUT_N + 1) * LUT_N + 1];
        return c000 + largest * (near - c000) + middle * (far - near) + smallest * (c111 - far);
    }

    // MARK: Exposure

    constant float3 kLuma = float3(0.2627002f, 0.6779981f, 0.0593017f);

    // The regional key the tone masks read, from the whole-frame grid.
    static inline float toneBase(Config cfg, float stops, int frameX, int frameY) {
        int gw = int(cfg[S_TONE_GRID_WIDTH]), gh = int(cfg[S_TONE_GRID_HEIGHT]);
        float fw = max(cfg[S_FRAME_WIDTH], 1.0f), fh = max(cfg[S_FRAME_HEIGHT], 1.0f);
        float gx = clamp((float(frameX) + 0.5f) * float(gw) / fw - 0.5f, 0.0f, float(gw - 1));
        float gy = clamp((float(frameY) + 0.5f) * float(gh) / fh - 0.5f, 0.0f, float(gh - 1));
        int x0 = clamp(int(gx), 0, max(gw - 2, 0)), y0 = clamp(int(gy), 0, max(gh - 2, 0));
        int x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1);
        float fx = clamp(gx - float(x0), 0.0f, 1.0f), fy = clamp(gy - float(y0), 0.0f, 1.0f);
        float2 value = float2(0.0f);
        for (int plane = 0; plane < 2; ++plane) {
            int at = plane == 0 ? S_TONE_GRID_A : S_TONE_GRID_B;
            float c00 = cfg[at + y0 * gw + x0], c10 = cfg[at + y0 * gw + x1];
            float c01 = cfg[at + y1 * gw + x0], c11 = cfg[at + y1 * gw + x1];
            value[plane] = (1.0f - fy) * ((1.0f - fx) * c00 + fx * c10) + fy * ((1.0f - fx) * c01 + fx * c11);
        }
        return value.x * stops + value.y;
    }

    // Scene light after the tone masks a metered frame sets: its highlights held and its shadows lifted, each by
    // the regional brightness around the pixel.
    static inline float3 tonedScene(Config cfg, float3 rgb, int frameX, int frameY) {
        float highlights = cfg[S_HIGHLIGHTS], shadows = cfg[S_SHADOWS];
        if (highlights == 0.0f && shadows == 0.0f) return rgb;
        float metered = dot(kLuma, rgb) * cfg[S_EXPOSURE_GAIN] * (1.0f / 0.18f);
        float keyed = toneBase(cfg, log2(max(metered, 1.0e-6f)), frameX, frameY);
        float toneEV = 3.0f * (highlights * smooth01(keyed * (1.0f / 6.0f)) + shadows * smooth01(-keyed * (1.0f / 6.0f)));
        return rgb * exp2(toneEV);
    }

    // Scene light to each record's exposure (1 is metered mid-grey), through the spectral cube: its chromaticity in
    // the cube's own basis, which encloses the spectral locus, at the radiance it is scaled back out by.
    static inline float4 sceneExposure(Config cfg, Table exposureLut, float3 rgb, int frameX, int frameY) {
        float3 s = tonedScene(cfg, rgb, frameX, frameY);
        float y = dot(kLuma, s);
        float3 d = float3(0.670231843f * s.r + 0.152168745f * s.g + 0.177599412f * s.b,
                          0.044501114f * s.r + 0.854482372f * s.g + 0.101016514f * s.b,
                          0.025777047f * s.g + 0.974222953f * s.b);
        // Colour outside the locus walks toward its own luminance until the binding channel reaches zero.
        float3 t = float3(d.x < 0.0f ? y / (y - d.x) : 1.0f, d.y < 0.0f ? y / (y - d.y) : 1.0f, d.z < 0.0f ? y / (y - d.z) : 1.0f);
        float walk = min(t.x, min(t.y, t.z));
        bool outside = d.x < 0.0f || d.y < 0.0f || d.z < 0.0f;
        float3 p = y <= 0.0f ? float3(0.0f) : (outside ? y + walk * (d - y) : d);
        float3 w = max(p, 0.0f);
        float radiance = max(max(w.x, max(w.y, w.z)), 1.0e-6f);
        return max(cube(exposureLut, w / radiance) * (radiance * cfg[S_EXPOSURE_GAIN] / 0.18f), 0.0f);
    }

    // The scene's exposure on the film: the three records, and beside them their neutral, which the emulsion's
    // spread blurs at its own width. A donor layer's fourth record goes to `donor`.
    kernel void exposeKernel(texture2d<float, access::read> scene, texture2d<float, access::write> exposure,
                             texture2d<float, access::write> donor, constant Tile &tile, Config cfg, Table exposureLut,
                             uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        float3 light = transformed(tile.sceneMatrix, scene.read(gid).rgb);
        float4 e = sceneExposure(cfg, exposureLut, light, int(gid.x) + tile.originX, int(gid.y) + tile.originY);
        exposure.write(float4(e.rgb, (e.r + e.g + e.b) / 3.0f), gid);
        if (tile.features & F_DONOR_LAYER) donor.write(float4(e.a), gid);
    }

    // MARK: Blurs and grids

    struct Blur {
        int width, height;      // the extent blurred; taps beyond it weigh nothing
        int radius, vertical;
        int weights;            // first tap's index in the weight table
    };

    // One direction of a separable blur, each channel by its own weights, normalized by the taps inside the extent.
    kernel void blurKernel(texture2d<float, access::read> source, texture2d<float, access::write> target,
                           constant Blur &blur, Table weights, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= blur.width || int(gid.y) >= blur.height) return;
        float4 sum = float4(0.0f), total = float4(0.0f);
        int2 step = blur.vertical ? int2(0, 1) : int2(1, 0);
        int at = blur.vertical ? int(gid.y) : int(gid.x), limit = blur.vertical ? blur.height : blur.width;
        int first = max(-blur.radius, -at), last = min(blur.radius, limit - 1 - at);
        for (int k = first; k <= last; ++k) {
            float4 weight = weights[blur.weights + k + blur.radius];
            sum += source.read(uint2(int2(gid) + k * step)) * weight;
            total += weight;
        }
        target.write(sum / max(total, 1.0e-12f), gid);
    }

    // The emulsion's spread, both of its scales at once: each record at its own width with the records' neutral at
    // the luminance width (`primary`), and each record at its second width (`secondary`).
    kernel void spreadKernel(texture2d<float, access::read> source, texture2d<float, access::write> primary,
                             texture2d<float, access::write> secondary, constant Blur &blur, Table weights,
                             uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= blur.width || int(gid.y) >= blur.height) return;
        float4 sum = float4(0.0f), total = float4(0.0f), sum2 = float4(0.0f), total2 = float4(0.0f);
        int taps = 2 * blur.radius + 1;
        int first = max(-blur.radius, -int(gid.x)), last = min(blur.radius, blur.width - 1 - int(gid.x));
        for (int k = first; k <= last; ++k) {
            float4 value = source.read(uint2(int(gid.x) + k, gid.y));
            float4 weight = weights[blur.weights + k + blur.radius], weight2 = weights[blur.weights + taps + k + blur.radius];
            sum += value * weight; total += weight;
            sum2 += value * weight2; total2 += weight2;
        }
        primary.write(sum / max(total, 1.0e-12f), gid);
        secondary.write(sum2 / max(total2, 1.0e-12f), gid);
    }

    // The spread's second direction and its mix: the two scales by each record's share, then the neutral's own
    // spread in place of the mix's.
    kernel void spreadMixKernel(texture2d<float, access::read> primary, texture2d<float, access::read> secondary,
                                texture2d<float, access::write> light, constant Blur &blur, Table weights,
                                constant Tile &tile, Config cfg, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= blur.width || int(gid.y) >= blur.height) return;
        bool profile = tile.features & F_MTF_LUMA;
        float4 sum = float4(0.0f), total = float4(0.0f), sum2 = float4(0.0f), total2 = float4(0.0f);
        int taps = 2 * blur.radius + 1;
        int first = max(-blur.radius, -int(gid.y)), last = min(blur.radius, blur.height - 1 - int(gid.y));
        for (int k = first; k <= last; ++k) {
            uint2 at = uint2(gid.x, int(gid.y) + k);
            float4 weight = weights[blur.weights + k + blur.radius];
            sum += primary.read(at) * weight; total += weight;
            if (profile) {
                float4 weight2 = weights[blur.weights + taps + k + blur.radius];
                sum2 += secondary.read(at) * weight2; total2 += weight2;
            }
        }
        float4 layers = sum / max(total, 1.0e-12f);
        float3 result = layers.rgb;
        if (profile) {
            float3 second = (sum2 / max(total2, 1.0e-12f)).rgb;
            float3 share = float3(cfg[S_MTF_PRIMARY_SHARE], cfg[S_MTF_PRIMARY_SHARE + 1], cfg[S_MTF_PRIMARY_SHARE + 2]);
            float3 mixed = share * layers.rgb + (1.0f - share) * second;
            result = mixed + cfg[S_MTF_LUMA_SHARE] * (layers.a - (mixed.r + mixed.g + mixed.b) / 3.0f);
        }
        light.write(float4(result, 1.0f), gid);
    }

    struct Decimate {
        int width, height;              // cells written
        int targetX, targetY;           // the first of them in the target
        int sourceWidth, sourceHeight;  // the source's extent; samples beyond it are not counted
        int factor;
        int shiftX, shiftY;             // cell (x, y) of the target starts at source (x * factor - shiftX, ...)
    };

    // A box-averaged grid: each cell the mean of the samples it holds inside the source.
    kernel void decimateKernel(texture2d<float, access::read> source, texture2d<float, access::write> target,
                               constant Decimate &grid, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= grid.width || int(gid.y) >= grid.height) return;
        int2 cell = int2(gid) + int2(grid.targetX, grid.targetY);
        int2 start = cell * grid.factor - int2(grid.shiftX, grid.shiftY);
        int2 low = max(start, int2(0)), high = min(start + grid.factor, int2(grid.sourceWidth, grid.sourceHeight));
        float4 sum = float4(0.0f);
        for (int y = low.y; y < high.y; ++y) for (int x = low.x; x < high.x; ++x) sum += source.read(uint2(x, y));
        float count = float(max(high.x - low.x, 0) * max(high.y - low.y, 0));
        target.write(sum / max(count, 1.0f), uint2(cell));
    }

    // A grid read at a fractional cell, with its weight beside it: cells off the grid hold nothing and weigh nothing.
    static inline void gridTap(texture2d<float, access::read> grid, int2 size, float2 at, thread float4 &value, thread float &weight) {
        float2 base = floor(at), f = at - base;
        int2 c = int2(base);
        for (int j = 0; j < 2; ++j) for (int i = 0; i < 2; ++i) {
            int2 q = c + int2(i, j);
            if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) continue;
            float w = (i ? f.x : 1.0f - f.x) * (j ? f.y : 1.0f - f.y);
            value += w * grid.read(uint2(q)); weight += w;
        }
    }

    // One halation scale's spread at a frame pixel.
    static inline float3 halationScale(texture2d<float, access::read> grid, constant Tile &tile, int scale, int2 frame) {
        float4 value = float4(0.0f); float weight = 0.0f;
        gridTap(grid, int2(tile.halationWidth[scale], tile.halationHeight[scale]), (float2(frame) + 0.5f) / float(tile.halationStride[scale]) - 0.5f, value, weight);
        return value.rgb / max(weight, 1.0e-12f);
    }

    // MARK: Development

    // The light on the film with what its base returns, as log exposure; a donor layer's beside it.
    kernel void logExposureKernel(texture2d<float, access::read> light, texture2d<float, access::read> donor,
                                  texture2d<float, access::read> halation0, texture2d<float, access::read> halation1,
                                  texture2d<float, access::read> halation2, texture2d<float, access::write> logExposure,
                                  constant Tile &tile, Config cfg, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        float3 direct = light.read(gid).rgb, exposed = direct;
        if (tile.features & F_HALATION) {
            int2 frame = int2(gid) + int2(tile.originX, tile.originY);
            float3 s0 = halationScale(halation0, tile, 0, frame), s1 = halationScale(halation1, tile, 1, frame);
            float3 s2 = halationScale(halation2, tile, 2, frame);
            float3 returned;
            for (int c = 0; c < 3; ++c) {
                int k = S_HALATION_KERNEL + c * 3;
                returned[c] = cfg[k] * s0[c] + cfg[k + 1] * s1[c] + cfg[k + 2] * s2[c] - direct[c];
            }
            for (int c = 0; c < 3; ++c) {
                int row = S_HALATION_MATRIX + c * 3;
                exposed[c] = direct[c] + cfg[row] * returned.r + cfg[row + 1] * returned.g + cfg[row + 2] * returned.b;
            }
        }
        float donorLog = (tile.features & F_DONOR_LAYER) ? log10(max(donor.read(gid).r, 1.0e-6f)) : 0.0f;
        logExposure.write(float4(log10(max(exposed, 1.0e-6f)), donorLog), gid);
    }

    // Normalized Hill law for the inhibitor a developing record releases.
    static inline float hill(float activation, float gamma) {
        float a = clamp(activation, 0.0f, 1.0f);
        if (gamma == 1.0f) return a;
        float released = pow(a, gamma), retained = pow(1.0f - a, gamma);
        return released / max(released + retained, 1.0e-8f);
    }
    static inline float3 activationOf(Config cfg, Table curves, float3 logExposure) {
        return (filmCurve(curves, logExposure) - filmBase(cfg)) / filmRanges(cfg);
    }
    // What each record releases at a pixel, and the donor layer in the fourth.
    static inline float4 releasedOf(Config cfg, Table curves, uint features, float4 logExposure) {
        float3 a = activationOf(cfg, curves, logExposure.rgb);
        float4 released = float4(hill(a.r, cfg[S_COUPLER_RELEASE_GAMMA]), hill(a.g, cfg[S_COUPLER_RELEASE_GAMMA + 1]),
                                 hill(a.b, cfg[S_COUPLER_RELEASE_GAMMA + 2]), 0.0f);
        if (features & F_DONOR_LAYER) {
            float formed = curveAt(curves, FILM_CURVE_SAMPLES, logExposure.a).a;
            released.a = hill((formed - cfg[S_DONOR_CURVE]) / max(curveRange(cfg, S_DONOR_CURVE), 1.0e-6f), cfg[S_DONOR_RELEASE_GAMMA]);
        }
        return released;
    }

    struct Field {
        int width, height;              // cells
        int sourceWidth, sourceHeight;
        int stride, phaseX, phaseY;
        int activation;                 // 1 for the records' activation, 0 for what they release
    };

    // What the film releases (or how far it has developed) on a grid anchored to the frame, for the chemistry that
    // diffuses over many pixels.
    kernel void fieldKernel(texture2d<float, access::read> logExposure, texture2d<float, access::write> target,
                            constant Field &field, constant Tile &tile, Config cfg, Table curves,
                            uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= field.width || int(gid.y) >= field.height) return;
        int2 start = int2(gid) * field.stride - int2(field.phaseX, field.phaseY);
        int2 low = max(start, int2(0)), high = min(start + field.stride, int2(field.sourceWidth, field.sourceHeight));
        float4 sum = float4(0.0f);
        for (int y = low.y; y < high.y; ++y) for (int x = low.x; x < high.x; ++x) {
            float4 value = logExposure.read(uint2(x, y));
            sum += field.activation ? float4(activationOf(cfg, curves, value.rgb), 0.0f) : releasedOf(cfg, curves, tile.features, value);
        }
        float count = float(max(high.x - low.x, 0) * max(high.y - low.y, 0));
        target.write(sum / max(count, 1.0f), gid);
    }

    // A diffused field read back at a tile pixel.
    static inline float4 fieldRead(texture2d<float, access::read> grid, constant Tile &tile, int index, uint2 gid) {
        float stride = float(tile.fieldStride[index]);
        float2 at = (float2(int2(gid) + int2(tile.fieldPhaseX[index], tile.fieldPhaseY[index])) + 0.5f) / stride - 0.5f;
        float4 value = float4(0.0f); float weight = 0.0f;
        gridTap(grid, int2(tile.fieldWidth[index], tile.fieldHeight[index]), at, value, weight);
        return value / max(weight, 1.0e-12f);
    }

    // The neutral anchor of the coupler stage: the log-exposure offset that undoes what a neutral of the same
    // luminance would have released.
    static inline float couplerWarp(Config cfg, int channel, float u) {
        float q = clamp((u - COUPLER_WARP_MIN) * (float(COUPLER_WARP_SAMPLES - 1) / (COUPLER_WARP_MAX - COUPLER_WARP_MIN)),
                        0.0f, float(COUPLER_WARP_SAMPLES - 1));
        int index = min(int(q), COUPLER_WARP_SAMPLES - 2);
        float frac = q - float(index);
        int base = S_COUPLER_WARP + channel * COUPLER_WARP_SAMPLES;
        float low = cfg[base + index], high = cfg[base + index + 1];
        bool nonlinear = cfg[S_COUPLER_RELEASE_GAMMA] != 1.0f || cfg[S_COUPLER_RELEASE_GAMMA + 1] != 1.0f
            || cfg[S_COUPLER_RELEASE_GAMMA + 2] != 1.0f || cfg[S_DONOR_RELEASE_GAMMA] != 1.0f;
        if (!nonlinear) return low + frac * (high - low);
        float previous = cfg[base + max(index - 1, 0)], following = cfg[base + min(index + 2, COUPLER_WARP_SAMPLES - 1)];
        float delta = max(high - low, 0.0f);
        float lowSlope = clamp(0.5f * (high - previous), 0.0f, 3.0f * delta), highSlope = clamp(0.5f * (following - low), 0.0f, 3.0f * delta);
        float f2 = frac * frac, f3 = f2 * frac;
        return (2.0f * f3 - 3.0f * f2 + 1.0f) * low + (f3 - 2.0f * f2 + frac) * lowSlope + (-2.0f * f3 + 3.0f * f2) * high + (f3 - f2) * highSlope;
    }

    // MARK: Grain

    static inline uint pcg(uint value) {
        uint state = value * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }
    static inline uint pixelHash(int x, int y, uint seed, uint layer) {
        return pcg(uint(x) ^ pcg(uint(y) ^ pcg(seed ^ (layer * 0x9E3779B9u))));
    }
    static inline float normalFromHash(uint hash) {
        uint hash2 = pcg(hash);
        float u1 = float(hash >> 8u) * (1.0f / 16777216.0f) + 1.0e-7f, u2 = float(hash2 >> 8u) * (1.0f / 16777216.0f);
        return sqrt(-2.0f * log(u1)) * cos(6.2831853f * u2);
    }
    // A centered, unit-variance count of dye clouds in a pixel; a normal draw where they are many.
    static inline float cloudSample(int x, int y, uint seed, float lambda, uint layer) {
        uint hash = pixelHash(x, y, seed, layer);
        if (lambda >= 16.0f) return normalFromHash(hash);
        float product = 1.0f, limit = exp(-lambda);
        int trials = 0;
        for (int i = 0; i < 32 && product > limit; ++i) {
            hash = pcg(hash);
            product *= float(hash >> 8u) * (1.0f / 16777216.0f);
            trials += 1;
        }
        return (float(max(trials - 1, 0)) - lambda) / sqrt(max(lambda, 1.0e-4f));
    }
    static inline float3 grainDraw(constant Tile &tile, Config cfg, int2 frame, float lambda, uint ownBase, uint sharedLayer) {
        if (tile.features & F_MONOCHROME) return float3(normalFromHash(pixelHash(frame.x, frame.y, tile.seed, sharedLayer)));
        float rho = clamp(cfg[S_GRAIN_CORRELATION], 0.0f, 1.0f);
        float shared = cloudSample(frame.x, frame.y, tile.seed, lambda, sharedLayer);
        float3 own = float3(cloudSample(frame.x, frame.y, tile.seed, lambda, ownBase), cloudSample(frame.x, frame.y, tile.seed, lambda, ownBase + 1u),
                            cloudSample(frame.x, frame.y, tile.seed, lambda, ownBase + 2u));
        return sqrt(1.0f - rho) * own + sqrt(rho) * shared;
    }

    // The grain's seed field, and the coarser one of its mottle: a draw for each pixel of the frame.
    kernel void grainSeedKernel(texture2d<float, access::write> grain, texture2d<float, access::write> mottle,
                                constant Tile &tile, Config cfg, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        int2 frame = int2(gid) + int2(tile.originX, tile.originY);
        grain.write(float4(grainDraw(tile, cfg, frame, tile.grainLambda, 0u, 3u), 0.0f), gid);
        if (tile.features & F_GRAIN_MOTTLE) mottle.write(float4(grainDraw(tile, cfg, frame, tile.mottleLambda, 4u, 7u), 0.0f), gid);
    }

    static inline float dyeCloudVariance(float density, float amplitude, float toe, float decay, float hump, float humpDensity, float humpWidth) {
        float offset = (density - humpDensity) / max(humpWidth, 1.0e-4f);
        return (1.0f - exp(-density / max(toe, 1.0e-4f))) * (1.0f + amplitude * exp(-density / max(decay, 1.0e-4f)) + hump * exp(-0.5f * offset * offset));
    }
    static inline float silverVariance(float density) { return density * exp10(0.21004f * density + 0.06114f * density * density); }
    static inline float reversalVariance(float density, float exponent, float shoulder) {
        float power = pow(density / max(shoulder, 1.0e-4f), 2.0f * exponent);
        return power / (1.0f + power);
    }
    // Granularity at a net density, relative to the density the stock's figure was read at.
    static inline float grainModulation(Config cfg, int layer, float netDensity) {
        float fog = cfg[S_GRAIN_FOG + layer];
        float anchor = max(cfg[S_GRAIN_ANCHOR + layer] + fog, 1.0e-4f), here = max(netDensity, 0.0f) + fog;
        float law = cfg[S_GRAIN_LAW], ratio;
        if (law > 2.5f) {
            float exponent = cfg[S_GRAIN_REVERSAL_PROFILE], shoulder = cfg[S_GRAIN_REVERSAL_PROFILE + 1];
            ratio = reversalVariance(here, exponent, shoulder) / max(reversalVariance(anchor, exponent, shoulder), 1.0e-20f);
        } else if (law > 1.5f) {
            ratio = here / anchor;
        } else if (law > 0.5f) {
            ratio = silverVariance(here) / max(silverVariance(anchor), 1.0e-6f);
        } else {
            int r = S_GRAIN_DENSITY_RECORDS + layer * 6;
            ratio = dyeCloudVariance(here, cfg[r], cfg[r + 1], cfg[r + 2], cfg[r + 3], cfg[r + 4], cfg[r + 5])
                / max(dyeCloudVariance(anchor, cfg[r], cfg[r + 1], cfg[r + 2], cfg[r + 3], cfg[r + 4], cfg[r + 5]), 1.0e-6f);
        }
        return sqrt(max(ratio, 0.0f));
    }

    // A scanned negative read as the film's densities: each record's base plus its gain times its weighted density
    // of the scan's channels over the clear film. The fourth channel says whether the sample could be placed at all.
    kernel void scanDensityKernel(texture2d<float, access::read> scan, texture2d<float, access::write> density,
                                  constant Tile &tile, Config cfg, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        float3 sample = scan.read(gid).rgb;
        bool readable = true;
        float3 over;
        for (int c = 0; c < 3; ++c) {
            readable = readable && sample[c] > cfg[S_SCAN_READING + 13 + c] && sample[c] < cfg[S_SCAN_READING + 16 + c];
            over[c] = -log10(max(sample[c], 1.0e-30f) / cfg[S_SCAN_READING + 1 + c]);
        }
        float3 result;
        for (int record = 0; record < 3; ++record) {
            int w = S_SCAN_CROSSTALK + record * 3;
            float base = cfg[S_SCAN_READING + 4 + record];
            float read = cfg[w] * over.r + cfg[w + 1] * over.g + cfg[w + 2] * over.b;
            result[record] = readable ? clamp(base + cfg[S_SCAN_READING + 10 + record] * read, -0.5f, 8.0f) : base;
        }
        density.write(float4(result, readable ? 1.0f : 0.0f), gid);
    }

    // The developed film: the couplers' inhibition and the adjacency effect on each record's exposure, the
    // characteristic curves, and the grain on the density they form. `source` is log exposure, or a scan's densities.
    // The density is written as it is, or as the light it passes for a print through an enlarger.
    kernel void developKernel(texture2d<float, access::read> source, texture2d<float, access::read> couplers,
                              texture2d<float, access::read> fringe, texture2d<float, access::read> adjacency,
                              texture2d<float, access::read> adjacencySecond, texture2d<float, access::read> grain,
                              texture2d<float, access::read> mottle, texture2d<float, access::write> developed,
                              constant Tile &tile, Config cfg, Table curves, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        uint features = tile.features;
        float4 read = source.read(gid);
        float3 base = filmBase(cfg), range = filmRanges(cfg);
        float3 density;
        float flag = 1.0f;
        if (features & F_DENSITY_IN) {
            density = read.rgb; flag = read.a;
        } else {
            float3 logExposure = read.rgb, effective = logExposure, residual = float3(0.0f);
            if (features & (F_COUPLERS | F_ADJACENCY | F_DONOR_LAYER)) {
                float3 activation = activationOf(cfg, curves, logExposure);
                float3 inhibited = logExposure;
                if (features & (F_COUPLERS | F_DONOR_LAYER)) {
                    bool diffuses = features & F_COUPLER_DIFFUSION;
                    float4 released = diffuses ? fieldRead(couplers, tile, 0, gid) : releasedOf(cfg, curves, features, read);
                    float scale = cfg[S_COUPLER_SCALE];
                    float3 inhibition = float3(0.0f);
                    if (features & F_COUPLERS) {
                        float3 delta = (diffuses && tile.fringeRadius > 0) ? fieldRead(fringe, tile, 1, gid).rgb - released.rgb : float3(0.0f);
                        for (int c = 0; c < 3; ++c) {
                            int k = S_COUPLER + c * 3;
                            inhibition[c] = (cfg[k] * released.r + cfg[k + 1] * released.g + cfg[k + 2] * released.b) * scale;
                            // The fringe redistributes only what crosses between layers.
                            float crossed = (c != 0 ? cfg[k] * delta.r : 0.0f) + (c != 1 ? cfg[k + 1] * delta.g : 0.0f) + (c != 2 ? cfg[k + 2] * delta.b : 0.0f);
                            inhibition[c] += crossed * scale * cfg[S_CHROMATIC_FRINGE_AMOUNT];
                        }
                    }
                    if (features & F_DONOR_LAYER) {
                        inhibition += float3(cfg[S_DONOR_RELEASE], cfg[S_DONOR_RELEASE + 1], cfg[S_DONOR_RELEASE + 2]) * released.a * scale;
                    }
                    float3 u = logExposure - inhibition;
                    inhibited = u + float3(couplerWarp(cfg, 0, u.r), couplerWarp(cfg, 1, u.g), couplerWarp(cfg, 2, u.b));
                }
                float3 shift = float3(0.0f);
                if (features & F_ADJACENCY) {
                    bool screened = cfg[S_ADJACENCY_MODEL] > 0.5f;
                    float3 transport = fieldRead(adjacency, tile, 2, gid).rgb;
                    if (screened) transport = 0.2753401713f * transport + (1.0f - 0.2753401713f) * fieldRead(adjacencySecond, tile, 3, gid).rgb;
                    residual = activation - transport;
                    if (!screened) shift = -cfg[S_ADJACENCY_STRENGTH] * residual;
                }
                effective = inhibited - shift;
            }
            float3 formed = filmCurve(curves, effective);
            if ((features & F_ADJACENCY) && cfg[S_ADJACENCY_MODEL] > 0.5f) {
                float3 net = max(formed - base, 0.0f);
                formed = base + clamp(net + cfg[S_ADJACENCY_STRENGTH] * net * residual, float3(0.0f), range);
            }
            density = cfg[S_DEVELOP_COMPLEMENT] > 0.5f ? base + range - (formed - base) : formed;
        }
        if (features & F_GRAIN) {
            float3 field = grain.read(gid).rgb;
            float3 coarse = (features & F_GRAIN_MOTTLE) ? mottle.read(gid).rgb : float3(0.0f);
            float3 net = clamp((density - base) / range, 0.0f, 1.0f) * range;
            for (int c = 0; c < 3; ++c) {
                float modulation = grainModulation(cfg, c, net[c]);
                density[c] += cfg[S_GRAIN + c] * modulation * field[c] + cfg[S_MOTTLE + c] * modulation * coarse[c];
            }
        }
        // The enlarger's spread works on the light the film passes, so a print that has one takes that light.
        developed.write(float4((features & F_PRINT_MTF) ? exp10(-density) : density, flag), gid);
    }

    // MARK: Print

    static inline float3 paperExposure(Config cfg, float3 relative) {
        float flash = cfg[S_PRINTER_PREFLASH];
        float3 effective = flash > 0.0f ? log10(max(exp10(relative) + flash, 1.0e-12f)) : relative;
        return float3(cfg[S_PAPER_MIDPOINT_RED], cfg[S_PAPER_MIDPOINT], cfg[S_PAPER_MIDPOINT_BLUE])
            + float3(cfg[S_MASKING], cfg[S_MASKING + 1], cfg[S_MASKING + 2]) * effective;
    }
    // Shadow and Highlight Detail: how far a pixel's log exposure moves on an axis where more prints darker.
    static inline float detailHold(Config cfg, float at, float mid, float black, float knee, float white) {
        float shadows = cfg[S_PRINT_DETAIL], highlights = cfg[S_PRINT_DETAIL + 1];
        float span = black - mid;
        float u = (at - mid) / max(span, 1.0e-3f);
        float shape = smooth01(u * (1.0f / 0.7f)) * (1.0f - smooth01((u - 0.75f) * (1.0f / (1.0f - 0.75f))));
        float hold = (shadows > 0.0f && span > 0.05f) ? shadows * 0.22f * span * shape : 0.0f;
        float room = knee - white, past = max(knee - at, 0.0f);
        float burn = (highlights > 0.0f && room > 0.05f) ? highlights * past * past / (past + room) : 0.0f;
        return hold - burn;
    }
    static inline float printKey(float3 e) { return 0.25f * e.r + 0.65f * e.g + 0.10f * e.b; }
    static inline float viewKey(float3 shown) { return -log10(max(dot(float3(0.2289746f, 0.6917385f, 0.0792869f), shown), 1.0e-6f)); }

    // The developed film printed: through the film cube to the light each paper record receives, the paper's
    // curves, and the paper cube to the picture; or the film itself where it is what is looked at. Where the enlarger
    // spreads the light, its blur takes its second direction here first.
    kernel void printKernel(texture2d<float, access::read> developed, texture2d<float, access::read> spread,
                            texture2d<float, access::write> picture, constant Tile &tile, constant Blur &blur, Table weights,
                            Config cfg, Table paperCurves, Table filmLut, Table paperLut,
                            uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= tile.width || int(gid.y) >= tile.height) return;
        uint features = tile.features;
        float4 read = developed.read(gid);
        float3 density = read.rgb;
        if (features & F_PRINT_MTF) {
            // `developed` holds the light the film passes, and `spread` that light blurred across.
            float4 sum = float4(0.0f), total = float4(0.0f);
            int first = max(-blur.radius, -int(gid.y)), last = min(blur.radius, blur.height - 1 - int(gid.y));
            for (int k = first; k <= last; ++k) {
                float4 weight = weights[blur.weights + k + blur.radius];
                sum += spread.read(uint2(gid.x, int(gid.y) + k)) * weight;
                total += weight;
            }
            float3 blurred = (sum / max(total, 1.0e-12f)).rgb;
            float keep = cfg[S_PRINT_SHARPEN];
            float3 passed = keep > 0.0f ? blurred + keep * (density - blurred) : blurred;
            density = -log10(max(passed, 1.0e-6f));
        }
        bool viewed = features & F_REVERSAL;
        float3 relative = cube(filmLut, (density - filmBase(cfg)) / filmRanges(cfg)).rgb;
        float hold = 0.0f;
        if (features & F_PRINT_DETAIL) {
            float3 clear = float3(cfg[S_PRINT_DETAIL + 4], cfg[S_PRINT_DETAIL + 5], cfg[S_PRINT_DETAIL + 6]);
            float3 dense = float3(cfg[S_PRINT_DETAIL + 7], cfg[S_PRINT_DETAIL + 8], cfg[S_PRINT_DETAIL + 9]);
            if (viewed) {
                hold = detailHold(cfg, viewKey(relative), 0.7447275f, viewKey(dense), 0.7447275f - 0.30103f, viewKey(clear) + 0.03f);
            } else {
                hold = detailHold(cfg, printKey(paperExposure(cfg, relative)), printKey(paperExposure(cfg, float3(0.0f))),
                                  max(printKey(paperExposure(cfg, clear)), printKey(paperExposure(cfg, dense))),
                                  cfg[S_PRINT_DETAIL + 2], cfg[S_PRINT_DETAIL + 3]);
            }
        }
        float3 display;
        if (viewed) {
            display = hold == 0.0f ? relative : relative * exp10(hold);
        } else {
            float3 paperBase = float3(cfg[S_PAPER_RED], cfg[S_PAPER], cfg[S_PAPER_BLUE]);
            float3 paperRange = float3(curveRange(cfg, S_PAPER_RED), curveRange(cfg, S_PAPER), curveRange(cfg, S_PAPER_BLUE));
            float3 activation = (paperCurve(paperCurves, paperExposure(cfg, relative) - hold) - paperBase) / paperRange;
            display = cube(paperLut, activation).rgb;
        }
        if (features & F_MONOCHROME) display = float3((display.r + display.g + display.b) / 3.0f);
        float3 printed = display;
        // What a scan's reading could not place, often the holder, prints black.
        if ((features & F_DENSITY_IN) && read.a < 0.5f) printed = float3(0.0f);
        picture.write(float4(transformed(tile.pictureMatrix, max(printed, 0.0f)), 1.0f), gid);
    }

    // MARK: Metering

    struct Meter {
        int width, rows;        // the frame's width, and the rows of this band
        int gridWidth;
        int firstLane, lanes;   // the grid columns this band's texture holds
        int firstColumn;        // the frame column its first texel is
        float scene[9];         // the scene's RGB to linear Rec. 2020, by rows
        float weights[12];      // four meters' weights on scene red, green and blue: the luminance, then each record alone
    };

    // The scene's brightness in stops, summed along each row inside each column of the regional tone grid.
    kernel void meterKernel(texture2d<float, access::read> scene, texture2d<float, access::write> sums,
                            constant Meter &meter, uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= meter.lanes || int(gid.y) >= meter.rows) return;
        int lane = int(gid.x) + meter.firstLane;
        int low = (lane * meter.width + meter.gridWidth - 1) / meter.gridWidth;
        int high = min(((lane + 1) * meter.width + meter.gridWidth - 1) / meter.gridWidth, meter.width);
        float4 total = float4(0.0f);
        for (int x = low; x < high; ++x) {
            float3 rgb = max(transformed(meter.scene, scene.read(uint2(x - meter.firstColumn, gid.y)).rgb), 0.0f);
            float4 metered;
            for (int m = 0; m < 4; ++m) metered[m] = meter.weights[m * 3] * rgb.r + meter.weights[m * 3 + 1] * rgb.g + meter.weights[m * 3 + 2] * rgb.b;
            total += log(max(metered, 1.0e-6f)) * (1.0f / 0.6931472f);
        }
        sums.write(total, uint2(lane, gid.y));
    }
    """#
}
