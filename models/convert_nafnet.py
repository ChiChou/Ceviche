"""Convert the official NAFNet-SIDD-width32 checkpoint to a fixed-tile Core ML package.

Usage: python convert_nafnet.py cache/NAFNet-SIDD-width32.pth build/NAFNetSIDD32.mlpackage
Input `image` and output `denoised` are float32 [1,3,512,512] sRGB tensors in [0,1].
"""
import sys

import coremltools as ct
import numpy as np
import torch

from nafnet_arch import NAFNet

TILE = 512

checkpoint, output = sys.argv[1], sys.argv[2]
model = NAFNet()
state = torch.load(checkpoint, map_location="cpu", weights_only=True)
model.load_state_dict(state["params"] if "params" in state else state, strict=True)
model.eval()

example = torch.rand(1, 3, TILE, TILE)
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="image", shape=example.shape)],
    outputs=[ct.TensorType(name="denoised")],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
mlmodel.short_description = "NAFNet-SIDD-width32 denoiser (megvii-research/NAFNet, MIT). 512x512 sRGB tiles in [0,1]."
mlmodel.license = "MIT (NAFNet) and Apache-2.0 (BasicSR)"
mlmodel.save(output)

# Compare against PyTorch on a noisy synthetic tile.
rng = np.random.default_rng(7)
clean = np.clip(rng.random((1, 3, TILE, TILE)).astype(np.float32) * 0.2 + 0.4, 0, 1)
noisy = np.clip(clean + rng.normal(0, 0.05, clean.shape).astype(np.float32), 0, 1)
with torch.no_grad():
    reference = model(torch.from_numpy(noisy)).numpy()
predicted = mlmodel.predict({"image": noisy})["denoised"]
print("max abs error vs PyTorch:", float(np.abs(predicted - reference).max()), "mean:", float(np.abs(predicted - reference).mean()))
