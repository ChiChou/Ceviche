"""Convert OpenCV Zoo's SFace face recognizer (ONNX, Apache-2.0) to Core ML.

SFace (MobileFaceNet backbone) sees a face aligned to 112 × 112 by five points (eye centres, nose tip, mouth corners;
OpenCV's FaceRecognizerSF.alignCrop) as RGB in 0…255, NCHW; the graph's own subtraction and scaling are kept, so the
input is unnormalized. The output is a 128-value embedding; Ceviche normalizes it and compares faces by cosine
similarity. The graph is mapped operator by operator (convolutions, batch norms, PReLU, flatten, the final linear layer)
and anything else is refused. The model is converted at FP16 and saved with INT8 weights, one scale per block of 32
(half the size at the same speed; on real faces the embeddings keep a cosine of 0.9998 to the original's). When ONNX
Runtime is installed, both are checked against it on random crops.
"""
import argparse
import hashlib

import coremltools as ct
import numpy as np
import onnx
from coremltools.converters.mil import Builder as mb
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from onnx import helper, numpy_helper

SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"


def require(condition, message):
    """Validate a graph assumption; unlike assert, this also runs under python -O."""
    if not condition:
        raise SystemExit(message)


def build(model):
    weights = {i.name: numpy_helper.to_array(i).copy() for i in model.graph.initializer}

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 112, 112))], opset_version=ct.target.macOS15)
    def program(data):
        x = data
        for node in model.graph.node:
            kind = node.op_type
            args = [weights[name] for name in node.input[1:] if name in weights]
            attributes = {a.name: helper.get_attribute_value(a) for a in node.attribute}
            if kind == "Sub":
                x = mb.sub(x=x, y=args[0])
            elif kind == "Mul":
                x = mb.mul(x=x, y=args[0])
            elif kind == "Conv":
                p = attributes["pads"]
                x = mb.conv(x=x, weight=args[0], bias=args[1] if len(args) > 1 else None, groups=attributes.get("group", 1),
                            strides=attributes["strides"], dilations=attributes["dilations"], pad_type="custom",
                            pad=[p[0], p[2], p[1], p[3]])
            elif kind == "BatchNormalization":
                if len(x.shape) == 2:
                    x = mb.reshape(x=x, shape=(1, x.shape[1], 1, 1))
                x = mb.batch_norm(x=x, gamma=args[0], beta=args[1], mean=args[2], variance=args[3], epsilon=attributes["epsilon"])
            elif kind == "PRelu":
                x = mb.prelu(x=x, alpha=args[0].reshape(-1))
            elif kind == "Flatten":
                x = mb.reshape(x=x, shape=(1, -1))
            elif kind == "Gemm":
                require(attributes.get("transB", 0) == 1, "Gemm without transB")
                x = mb.linear(x=x, weight=args[0], bias=args[1])
            else:
                require(kind == "Dropout", f"unsupported operator {kind}")
        return mb.reshape(x=x, shape=(1, 128), name="embedding")

    return program


def check(path, mlmodel, minimum):
    try:
        import onnxruntime
    except ImportError:
        print("onnxruntime not installed; skipping the parity check")
        return
    model = onnx.load(path)
    initializers = {i.name for i in model.graph.initializer}
    inputs = [i for i in model.graph.input if i.name not in initializers]
    del model.graph.input[:]
    model.graph.input.extend(inputs)
    session = onnxruntime.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    rng = np.random.default_rng(7)
    worst = 1.0
    for _ in range(8):
        crop = rng.uniform(0, 255, (1, 3, 112, 112)).astype(np.float32)
        reference = session.run(None, {name: crop})[0].reshape(-1)
        converted = mlmodel.predict({"data": crop})["embedding"].reshape(-1)
        cosine = float(reference @ converted / np.linalg.norm(reference) / np.linalg.norm(converted))
        worst = min(worst, cosine)
    print(f"cosine against ONNX Runtime, worst of 8: {worst:.6f}")
    require(worst > minimum, "the Core ML model disagrees with ONNX Runtime")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("onnx")
    parser.add_argument("destination")
    options = parser.parse_args()
    with open(options.onnx, "rb") as f:
        require(hashlib.sha256(f.read()).hexdigest() == SHA256, "unexpected SFace checksum")
    program = build(onnx.load(options.onnx))
    mlmodel = ct.convert(program, minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    check(options.onnx, mlmodel, 0.999)
    mlmodel = linear_quantize_weights(mlmodel, OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_block", block_size=32)))
    mlmodel.short_description = "SFace face embedding (OpenCV Zoo, Apache-2.0), INT8 weights: aligned 112x112 RGB 0-255 in, 128 values out"
    mlmodel.save(options.destination)
    check(options.onnx, mlmodel, 0.995)
