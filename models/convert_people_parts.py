"""Convert MediaPipe's Selfie Multiclass segmentation model (TFLite, Apache-2.0) to Core ML.

The model sees the photo squeezed to 256 × 256, RGB scaled to −1…1, and gives six class scores per pixel: background,
hair, body skin, face skin, clothes, others. The graph is mapped operator by operator by
tflite_mil.py, and the converted model is checked against the TFLite runtime when it is installed.
"""
import argparse
import hashlib

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb

from tflite_mil import NCHW, NHWC, Graph

SHA256 = "c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0"


def build(path):
    graph = Graph(path)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 256, 256))])
    def program(image):
        values = graph.build({graph.input: mb.transpose(x=image, perm=NHWC)})
        scores = mb.transpose(x=values[graph.output(0)], perm=NCHW)
        # Probabilities per class, so a mask is one channel read straight from the output.
        return mb.softmax(x=scores, axis=1, name="parts")

    return program


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tflite")
    parser.add_argument("destination")
    args = parser.parse_args()
    with open(args.tflite, "rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != SHA256:
            raise SystemExit("Unexpected model SHA-256")
    program = build(args.tflite)
    model = ct.convert(program, inputs=[ct.ImageType(name="image", shape=(1, 3, 256, 256), scale=2 / 255, bias=[-1] * 3)],
                       outputs=[ct.TensorType(name="parts")], compute_precision=ct.precision.FLOAT16,
                       minimum_deployment_target=ct.target.macOS15)
    model.short_description = "People parts: background, hair, body skin, face skin, clothes, others, at 256 × 256"
    model.save(args.destination)
    try:
        from ai_edge_litert.interpreter import Interpreter
        from PIL import Image
    except ImportError:
        print("TFLite runtime not installed; skipped the comparison")
        raise SystemExit
    rng = np.random.default_rng(1)
    pixels = rng.integers(0, 256, (256, 256, 3), dtype=np.uint8)
    reference = Interpreter(model_path=args.tflite)
    reference.allocate_tensors()
    reference.set_tensor(reference.get_input_details()[0]["index"], (pixels.astype(np.float32) / 127.5 - 1)[None])
    reference.invoke()
    logits = reference.get_tensor(reference.get_output_details()[0]["index"])[0]
    expected = np.exp(logits - logits.max(-1, keepdims=True))
    expected = (expected / expected.sum(-1, keepdims=True)).transpose(2, 0, 1)
    output = ct.models.MLModel(args.destination).predict({"image": Image.fromarray(pixels)})["parts"][0]
    error = np.abs(output - expected)
    agree = (output.argmax(0) == expected.argmax(0)).mean()
    print(f"max |Core ML − TFLite| {error.max():.4f}, mean {error.mean():.5f}, same class {agree:.4f}")
