"""Convert the detector in Alibaba's joint skin-retouching checkpoint to Core ML."""
import argparse
import hashlib

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F


class Block(nn.Module):
    def __init__(self, inputs, outputs, down, normalize=True):
        super().__init__()
        self.conv = nn.Conv2d(inputs, outputs, 3, 2 if down else 1, 1, bias=False)
        self.bn = nn.BatchNorm2d(outputs) if normalize else nn.Identity()
        self.activation = nn.ReLU() if down else nn.LeakyReLU(0.2)

    def forward(self, image):
        return self.activation(self.bn(self.conv(image)))


class Detector(nn.Module):
    def __init__(self):
        super().__init__()
        channels = [3, 64, 128, 256, 512, 512, 512]
        for level in range(1, 7):
            inputs, outputs = channels[level - 1:level + 1]
            setattr(self, f"ec_images_{level}", Block(inputs, outputs, True, level != 1))
            decoder = (nn.Conv2d(outputs + inputs, 1, 1) if level == 1
                       else Block(outputs + inputs, inputs, False))
            setattr(self, f"dc_images_{level}", decoder)

    def forward(self, image):
        skips = [image]
        for level in range(1, 7):
            skips.append(getattr(self, f"ec_images_{level}")(skips[-1]))
        result = skips.pop()
        for level in range(6, 0, -1):
            result = F.interpolate(result, scale_factor=2, mode="nearest")
            result = getattr(self, f"dc_images_{level}")(torch.cat((result, skips.pop()), dim=1))
        return torch.sigmoid(result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint")
    parser.add_argument("destination")
    args = parser.parse_args()
    with open(args.checkpoint, "rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != "c9e1388b19d9334c90db08308c86de208f535920ee381ae8a9cb63484a78351a":
            parser.error("Unexpected checkpoint SHA-256")
    model = Detector().eval()
    model.load_state_dict(torch.load(args.checkpoint, weights_only=True, map_location="cpu")["detection_net"])
    shape = (1, 3, 768, 768)
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.zeros(shape), check_trace=False)
    ct.convert(traced, inputs=[ct.ImageType(name="face", shape=shape, scale=2/255, bias=[-1]*3)],
               outputs=[ct.TensorType(name="spots", dtype=np.float32)],
               minimum_deployment_target=ct.target.macOS15).save(args.destination)
