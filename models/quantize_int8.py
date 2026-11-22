"""Write the INT8 copy of a converted model: weights quantized linearly to 8 bits, one scale per output channel.

Usage: python quantize_int8.py build/NAFNetSIDD32.mlpackage build/NAFNetSIDD32-INT8.mlpackage

Per-channel scales keep every model on the Neural Engine at the speed of the FP16 copy (per-block scales were two to
five times slower there). Activations stay FP16. A neural-network .mlmodel (the sky model) has its FP16 weights
widened first, since the legacy quantizer only reads FP32 ones. The copy keeps the source's inputs,
outputs and metadata, so the app loads either one the same way.
"""
import argparse
import os
import shutil

import coremltools as ct
import numpy as np
from coremltools.models.neural_network import quantization_utils
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

CONFIG = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))


def quantize_program(source, destination):
    linear_quantize_weights(ct.models.MLModel(source, skip_model_load=True), CONFIG).save(destination)


def quantize_neural_network(source, destination):
    spec = ct.models.MLModel(source, skip_model_load=True).get_spec()
    for layer in spec.neuralNetwork.layers:
        params = getattr(layer, layer.WhichOneof("layer"))
        for field, values in params.ListFields():
            if field.message_type is None or field.message_type.name != "WeightParams": continue
            if len(values.float16Value):
                widened = np.frombuffer(values.float16Value, np.float16).astype(np.float32)
                values.ClearField("float16Value"); values.floatValue.extend(widened.tolist())
    widened = ct.models.MLModel(spec, skip_model_load=True)
    quantization_utils.quantize_weights(widened, nbits=8, quantization_mode="linear").save(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source"); parser.add_argument("destination")
    args = parser.parse_args()
    shutil.rmtree(args.destination, ignore_errors=True)
    if os.path.isfile(args.destination): os.remove(args.destination)
    spec = ct.models.MLModel(args.source, skip_model_load=True).get_spec()
    if spec.WhichOneof("Type") == "neuralNetwork":
        quantize_neural_network(args.source, args.destination)
    elif len(spec.description.functions) > 0:
        raise SystemExit(f"{args.source} has several functions; quantize_int8.py takes single-function models only")
    else:
        quantize_program(args.source, args.destination)
    def size(path):
        return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs) if os.path.isdir(path) else os.path.getsize(path)
    print(f"{os.path.basename(args.destination)}: {size(args.source) / 1e6:.1f} MB -> {size(args.destination) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
