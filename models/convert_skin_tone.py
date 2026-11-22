"""Convert the even-tone network in Alibaba's skin-retouching model to Core ML.

The network sees a face crop at 512 × 512 (RGB scaled to −1…1) and predicts a blend layer, 0…1 per channel, that
is applied to the full-resolution crop as soft light: out = (1 − 2m)·I² + 2m·I. A layer of 0.5 changes nothing.
"""
import argparse
import hashlib

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F


def double(inputs, outputs):
    return nn.Sequential(nn.Conv2d(inputs, outputs, 3, padding=1), nn.BatchNorm2d(outputs), nn.ReLU(),
                         nn.Conv2d(outputs, outputs, 3, padding=1), nn.BatchNorm2d(outputs), nn.ReLU())


class Wrap(nn.Module):
    """Holds a module under the attribute name the checkpoint uses."""
    def __init__(self, name, module):
        super().__init__()
        setattr(self, name, module)
        self.name = name

    def forward(self, x):
        return getattr(self, self.name)(x)


class Up(nn.Module):
    def __init__(self, inputs, outputs):
        super().__init__()
        self.conv = Wrap("conv", double(inputs, outputs))

    def forward(self, low, skip):
        low = F.interpolate(low, scale_factor=2, mode="bilinear", align_corners=True)
        return self.conv(torch.cat([skip, low], dim=1))


class UNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.inc = Wrap("conv", Wrap("conv", double(3, 64)))
        self.down1 = Wrap("mpconv", nn.Sequential(nn.MaxPool2d(2), Wrap("conv", double(64, 128))))
        self.down2 = Wrap("mpconv", nn.Sequential(nn.MaxPool2d(2), Wrap("conv", double(128, 256))))
        self.down3 = Wrap("mpconv", nn.Sequential(nn.MaxPool2d(2), Wrap("conv", double(256, 512))))
        self.down4 = Wrap("mpconv", nn.Sequential(nn.MaxPool2d(2), Wrap("conv", double(512, 512))))
        self.up1, self.up2, self.up3, self.up4 = Up(1024, 256), Up(512, 128), Up(256, 64), Up(128, 64)
        self.outc = Wrap("conv", nn.Conv2d(64, 3, 1))

    def forward(self, x):
        x1 = self.inc(x)
        x2 = self.down1(x1)
        x3 = self.down2(x2)
        x4 = self.down3(x3)
        x5 = self.down4(x4)
        x = self.up1(x5, x4)
        x = self.up2(x, x3)
        x = self.up3(x, x2)
        x = self.up4(x, x1)
        return torch.sigmoid(self.outc(x))


def load(checkpoint):
    with open(checkpoint, "rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != "760d0c0b95c4e0a692165677fe2b82dbdf8fbbd4a3780ca966599c627b082993":
            raise SystemExit("Unexpected checkpoint SHA-256")
    state = torch.load(checkpoint, weights_only=True, map_location="cpu")["generator"]
    # The deep-supervision heads are unused at inference.
    state = {k: v for k, v in state.items() if not k.startswith("dsoutc")}
    # The checkpoint nests the inconv's sequential one level deeper than the others: inc.conv.conv.N.
    model = UNet().eval()
    model.load_state_dict(state, strict=True)
    return model


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint")
    parser.add_argument("destination")
    args = parser.parse_args()
    model = load(args.checkpoint)
    shape = (1, 3, 512, 512)
    example = torch.rand(shape) * 2 - 1
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
        reference = model(example).numpy()
    mlmodel = ct.convert(traced, inputs=[ct.ImageType(name="face", shape=shape, scale=2 / 255, bias=[-1] * 3)],
                         outputs=[ct.TensorType(name="blend", dtype=np.float32)],
                         compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    mlmodel.short_description = "Even skin tone: a soft-light blend layer for a 512 × 512 face crop"
    mlmodel.save(args.destination)
    # The traced model against PyTorch, on an image the converter quantizes to 8 bits as Core ML will.
    pixels = np.clip(((example[0].numpy() + 1) / 2 * 255).round(), 0, 255).astype(np.uint8).transpose(1, 2, 0)
    quantized = torch.from_numpy(pixels.transpose(2, 0, 1)[None].astype(np.float32) * 2 / 255 - 1)
    with torch.no_grad():
        reference = model(quantized).numpy()
    try:
        from PIL import Image  # coremltools takes image inputs as PIL images
        output = ct.models.MLModel(args.destination).predict({"face": Image.fromarray(pixels)})["blend"]
        print("max |Core ML − PyTorch|:", float(np.abs(output - reference).max()), "mean:", float(np.abs(output - reference).mean()))
    except Exception as error:  # prediction needs macOS; conversion alone is still useful
        print("skipped the Core ML check:", error)
