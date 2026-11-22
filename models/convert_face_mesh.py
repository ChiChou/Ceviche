"""Convert the face mesh of MediaPipe's Face Landmarker (TFLite, Apache-2.0) to Core ML.

The bundle (face_landmarker.task) holds a face detector, the mesh and a blendshape model; only the mesh is converted,
since Vision finds faces. The mesh sees a face crop at 256 × 256 (the face with a quarter of its size around it, RGB
scaled to 0…1) and gives 478 points (x, y in the crop's pixels, z relative to the face), including the lips' inner and
outer contours and each iris, plus a face score. The graph is mapped operator by operator by tflite_mil.py and checked
against the TFLite runtime when it is installed.
"""
import argparse
import hashlib
import io
import zipfile

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb

from tflite_mil import NHWC, Graph

SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
MEMBER = "face_landmarks_detector.tflite"


def build(path):
    graph = Graph(path)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 256, 256))])
    def program(face):
        values = graph.build({graph.input: mb.transpose(x=face, perm=NHWC)})
        points = mb.reshape(x=values[graph.output(0)], shape=[478, 3], name="landmarks")
        score = mb.reshape(x=values[graph.output(1)], shape=[1], name="score")
        return points, score

    return program


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task")
    parser.add_argument("destination")
    args = parser.parse_args()
    data = open(args.task, "rb").read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("Unexpected model SHA-256")
    import tempfile, os
    with zipfile.ZipFile(io.BytesIO(data)) as bundle, tempfile.TemporaryDirectory() as work:
        mesh = os.path.join(work, MEMBER)
        open(mesh, "wb").write(bundle.read(MEMBER))
        program = build(mesh)
        model = ct.convert(program, inputs=[ct.ImageType(name="face", shape=(1, 3, 256, 256), scale=1 / 255)],
                           outputs=[ct.TensorType(name="landmarks"), ct.TensorType(name="score")], compute_precision=ct.precision.FLOAT16,
                           minimum_deployment_target=ct.target.macOS15)
        model.short_description = "Face mesh: 478 points of a 256 × 256 face crop, and a face score"
        model.save(args.destination)
        try:
            from ai_edge_litert.interpreter import Interpreter
            from PIL import Image
        except ImportError:
            print("TFLite runtime not installed; skipped the comparison")
            raise SystemExit
        rng = np.random.default_rng(1)
        pixels = rng.integers(0, 256, (256, 256, 3), dtype=np.uint8)
        reference = Interpreter(model_path=mesh)
        reference.allocate_tensors()
        reference.set_tensor(reference.get_input_details()[0]["index"], (pixels.astype(np.float32) / 255)[None])
        reference.invoke()
        expected = reference.get_tensor(reference.get_output_details()[0]["index"]).reshape(478, 3)
        output = ct.models.MLModel(args.destination).predict({"face": Image.fromarray(pixels)})["landmarks"]
        error = np.abs(output - expected)[:, :2]
        print(f"max |Core ML − TFLite| {error.max():.3f} px, mean {error.mean():.4f} px (x, y in the 256 crop)")
