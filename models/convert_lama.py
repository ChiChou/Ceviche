"""Convert the Big-LaMa inpainting checkpoint (advimman/lama, Apache-2.0) to a Core ML package of fixed-size functions.

Usage: python convert_lama.py cache/big-lama.ckpt build/BigLaMa.mlpackage [--check photo.png]
Functions `inpaint512` (the default) and `inpaint1024` share one copy of the FP16 weights. Inputs are float32 `image`
[1,3,S,S], sRGB in [0,1], and `mask` [1,1,S,S], where values above 0.5 are the hole. Output `filled` [1,3,S,S] is the
generator's prediction everywhere; the app keeps it only inside the hole. Every operation runs on the Neural Engine.
"""
import argparse
import os
import pickle
import shutil
import sys
import tempfile
import types

import coremltools as ct
from coremltools.proto import Model_pb2
import numpy as np
import torch

from lama_arch import FFCResNetGenerator

SIZES = (512, 1024)


class Ignored:
    """Stands in for the checkpoint's training objects (Lightning callbacks, OmegaConf configs); never runs their code."""
    def __init__(self, *args, **kwargs): pass
    def __setstate__(self, state): pass
    def __call__(self, *args, **kwargs): return Ignored()


class RestrictedUnpickler(pickle.Unpickler):
    TENSORS = {("torch._utils", "_rebuild_tensor_v2"), ("torch", "FloatStorage"), ("torch", "LongStorage"),
               ("collections", "OrderedDict")}

    def find_class(self, module, name):
        if (module, name) in self.TENSORS: return super().find_class(module, name)
        if module == "__builtin__": module = "builtins"  # protocol 2 names, as Python 2 wrote them
        if (module, name) in {("builtins", "dict"), ("builtins", "list"), ("builtins", "int"), ("collections", "defaultdict")}: return super().find_class(module, name)
        if (module, name) == ("builtins", "long"): return int
        if module.split(".")[0] in ("omegaconf", "pytorch_lightning", "typing"): return Ignored
        raise pickle.UnpicklingError(f"{module}.{name} is not allowed in the checkpoint")


def load_generator(checkpoint):
    restricted = types.SimpleNamespace(Unpickler=RestrictedUnpickler, load=pickle.load, __name__="restricted")
    state = torch.load(checkpoint, map_location="cpu", pickle_module=restricted, weights_only=False)["state_dict"]
    generator = FFCResNetGenerator()
    generator.load_state_dict(FFCResNetGenerator.remap(state), strict=True)
    return generator.eval().fold_batch_norms()


class Inpainter(torch.nn.Module):
    """LaMa's inference step: the hole blanked out, the mask appended as a fourth channel."""
    def __init__(self, generator):
        super().__init__()
        self.generator = generator

    def forward(self, image, mask):
        hole = (mask > 0.5).float()
        return self.generator(torch.cat((image * (1 - hole), hole), dim=1))


def test_inputs(size, photo):
    """A seeded photo-like tensor (or a crop of `photo`) with a hole of brush strokes and a box, as LaMa was trained on."""
    rng = np.random.default_rng(7)
    if photo:
        from PIL import Image
        picture = Image.open(photo).convert("RGB")
        left, top = (picture.width - size) // 2, (picture.height - size) // 2
        image = np.asarray(picture.crop((left, top, left + size, top + size)), dtype=np.float32).transpose(2, 0, 1)[None] / 255
    else:
        y, x = np.mgrid[0:size, 0:size] / size
        image = np.stack([0.5 + 0.3 * np.sin(9 * x + c) * np.cos(7 * y) for c in range(3)])[None].astype(np.float32)
        image = np.clip(image + rng.normal(0, 0.03, image.shape).astype(np.float32), 0, 1)
    mask = np.zeros((1, 1, size, size), np.float32)
    s = size // 8
    mask[..., 3 * s:5 * s, 2 * s:4 * s] = 1
    for _ in range(3):
        cx, cy = rng.integers(s, size - s, 2)
        for t in np.linspace(0, 1, 40):
            px, py = int(cx + (t - 0.5) * 3 * s), int(cy + np.sin(t * 6) * s)
            mask[..., max(0, py - s // 6):py + s // 6, max(0, px - s // 6):px + s // 6] = 1
    return image, mask


def compare(mlmodel, model, size, photo=None):
    """Hole error against PyTorch. FP16 differs by a few levels in places, like a slightly different hallucination;
    Inf or a large mean error means activations overflowed (see FFCResNetGenerator.fold_batch_norms)."""
    image, mask = test_inputs(size, photo)
    with torch.no_grad():
        reference = model(torch.from_numpy(image), torch.from_numpy(mask)).numpy()
    predicted = mlmodel.predict({"image": image, "mask": mask})["filled"]
    if not np.isfinite(predicted).all(): sys.exit(f"{size}: the converted model produced non-finite values")
    error = np.abs(predicted - reference)[np.broadcast_to(mask > 0.5, reference.shape)]
    print(f"{size} {'photo' if photo else 'synthetic'} hole error vs PyTorch: mean {error.mean():.6f}, "
          f"p99 {np.percentile(error, 99):.6f}, max {error.max():.6f}")
    if error.mean() > 0.01: sys.exit(f"{size}: mean hole error {error.mean():.4f} is too large")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint"); parser.add_argument("output")
    parser.add_argument("--check", help="a photo at least 1024 px on each side to compare on as well")
    args = parser.parse_args()

    model = Inpainter(load_generator(args.checkpoint)).eval()
    descriptor = ct.utils.MultiFunctionDescriptor()
    with tempfile.TemporaryDirectory() as work:
        for size in SIZES:
            image, mask = (torch.from_numpy(t) for t in test_inputs(size, None))
            mlmodel = ct.convert(
                torch.jit.trace(model, (image, mask)),
                inputs=[ct.TensorType(name="image", shape=image.shape), ct.TensorType(name="mask", shape=mask.shape)],
                outputs=[ct.TensorType(name="filled")],
                compute_precision=ct.precision.FLOAT16,
                compute_units=ct.ComputeUnit.ALL,
                minimum_deployment_target=ct.target.macOS15,
            )
            compare(mlmodel, model, size)
            if args.check: compare(mlmodel, model, size, args.check)
            path = os.path.join(work, f"{size}.mlpackage")
            mlmodel.save(path)
            descriptor.add_function(path, src_function_name="main", target_function_name=f"inpaint{size}")
        descriptor.default_function_name = f"inpaint{SIZES[0]}"
        shutil.rmtree(args.output, ignore_errors=True)
        ct.utils.save_multifunction(descriptor, args.output)
    # save_multifunction keeps no metadata, so it is written into the package's spec directly.
    spec_path = os.path.join(args.output, "Data", "com.apple.CoreML", "model.mlmodel")
    spec = Model_pb2.Model()
    with open(spec_path, "rb") as f: spec.ParseFromString(f.read())
    spec.description.metadata.shortDescription = ("Big-LaMa inpainting (advimman/lama, Apache-2.0). Functions " + ", ".join(f"inpaint{s}" for s in SIZES) +
                                                  " take a square sRGB image in [0,1] and a mask whose values above 0.5 are the hole.")
    spec.description.metadata.license = "Apache-2.0"
    with open(spec_path, "wb") as f: f.write(spec.SerializeToString())
    print("Saved", args.output)


if __name__ == "__main__":
    main()
