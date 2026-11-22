"""Convert the U²-Net sky segmentation model's fixed-shape ONNX graph to Core ML.

Usage: python convert_sky.py cache/skyseg.onnx build/SkySegmentation.mlmodel
Run by fetch-models.sh; the upstream model is MIT (see MODELS.md).
Dependencies: numpy, onnx, coremltools. No ONNX runtime is needed, and nothing here ships
in the app. The converter rejects unrecognized operators.

The graph's shape arithmetic (Shape, Gather, Slice, Concat of sizes and so on) is folded at the fixed 320 × 320 input,
only the fused output (`1959`) and what it needs are kept, the ImageNet normalization the model was trained with is
put in front so callers pass encoded sRGB in [0, 1], and weights are stored as float16.
"""

import argparse
import collections

import coremltools as ct
import numpy as np
import onnx
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.neural_network.quantization_utils import quantize_weights
from onnx.reference import ReferenceEvaluator

# SkyMaskModel.swift looks up the model's tensors by these names.
INPUT_NAME, OUTPUT_NAME = 'modelInput', 'modelOutput'
# The side output fused from all six stages; the others are training aids.
FUSED_OUTPUT = '1959'
MEAN, STD = np.array([0.485, 0.456, 0.406], np.float32), np.array([0.229, 0.224, 0.225], np.float32)


def require(condition, message):
    """Validate a graph assumption; unlike assert, this also runs under python -O."""
    if not condition:
        raise ValueError(message)


def needed_nodes(graph, output):
    """The nodes the given output depends on, in graph order."""
    producer = {name: node for node in graph.node for name in node.output}
    needed, stack = set(), [output]
    while stack:
        node = producer.get(stack.pop())
        if node is None or id(node) in needed:
            continue
        needed.add(id(node))
        stack.extend(name for name in node.input if name)
    return [node for node in graph.node if id(node) in needed]


def convert(source, destination):
    model = onnx.shape_inference.infer_shapes(onnx.load(source), data_prop=True)
    shapes = {
        v.name: [d.dim_value for d in v.type.tensor_type.shape.dim]
        for v in list(model.graph.value_info) + list(model.graph.input) + list(model.graph.output)
    }
    constants = {v.name: onnx.numpy_helper.to_array(v) for v in model.graph.initializer}
    opsets = {entry.domain: entry.version for entry in model.opset_import}
    require(len(model.graph.input) == 1, 'Expected exactly one graph input')
    source_input = model.graph.input[0].name
    input_shape = shapes[source_input]
    require(input_shape[:2] == [1, 3] and input_shape[2] == input_shape[3], f'Expected a square RGB input, got {input_shape}')
    output_shape = [1, 1] + input_shape[2:]
    renamed = {FUSED_OUTPUT: OUTPUT_NAME}
    builder = NeuralNetworkBuilder(
        [(INPUT_NAME, datatypes.Array(*input_shape))],
        [(OUTPUT_NAME, datatypes.Array(*output_shape))],
        disable_rank5_shape_mapping=True,
        use_float_arraytype=True,
    )
    # (x − mean) / std as one multiply and one add, broadcast over each channel.
    builder.add_load_constant_nd('normalize_scale', 'normalize_scale', (1 / STD).reshape(1, 3, 1, 1), (1, 3, 1, 1))
    builder.add_load_constant_nd('normalize_bias', 'normalize_bias', (-MEAN / STD).reshape(1, 3, 1, 1), (1, 3, 1, 1))
    builder.add_multiply_broadcastable('normalize_multiply', [INPUT_NAME, 'normalize_scale'], 'normalize_scaled')
    builder.add_add_broadcastable('normalize_add', ['normalize_scaled', 'normalize_bias'], source_input)

    # Shapes as the conversion produces them: inference stops at the first Resize whose size is computed.
    known = {source_input: list(input_shape)}
    loaded = set()
    retained = collections.Counter()
    for index, node in enumerate(needed_nodes(model.graph, FUSED_OUTPUT)):
        attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
        if node.op_type == 'Shape' and node.input[0] in known:
            constants[node.output[0]] = np.array(known[node.input[0]], dtype=np.int64)
            continue
        if node.op_type == 'Unsqueeze' and node.input[0] in constants and 'axes' in attrs:
            # Opset 11 gives the axes as an attribute, which the reference evaluator's newer operator rejects.
            value = constants[node.input[0]]
            for axis in sorted(a % (value.ndim + len(attrs['axes'])) for a in attrs['axes']):
                value = np.expand_dims(value, axis)
            constants[node.output[0]] = value
            continue
        if all(name in constants for name in node.input if name):
            result = ReferenceEvaluator(node, opsets=opsets).run(
                None, {name: constants[name] for name in node.input if name}
            )
            constants.update(zip(node.output, result))
            continue
        inputs = [renamed.get(value, value) for value in node.input]
        out = renamed.get(node.output[0], node.output[0])
        name = f'{index}_{node.op_type}'
        # Convolution parameters and Resize sizes are attributes in Core ML.
        data_inputs = inputs[:1] if node.op_type in ('Conv', 'Resize') else inputs
        for value in data_inputs:
            if value in constants and value not in loaded:
                array = constants[value].astype(np.float32)
                builder.add_load_constant_nd(f'constant_{value}', value, array, array.shape)
                loaded.add(value)
        if node.op_type == 'Conv':
            w = constants[inputs[1]]
            b = constants[inputs[2]] if len(inputs) > 2 else None
            pads = list(attrs.get('pads', [0] * 4))
            require(attrs.get('auto_pad', b'NOTSET') == b'NOTSET', f'{name}: unsupported auto_pad')
            stride = attrs.get('strides', [1, 1])
            n, _, h, w_ = known[node.input[0]]
            dilation = attrs.get('dilations', [1, 1])
            known[node.output[0]] = [n, w.shape[0],
                                     (h + pads[0] + pads[2] - dilation[0] * (w.shape[2] - 1) - 1) // stride[0] + 1,
                                     (w_ + pads[1] + pads[3] - dilation[1] * (w.shape[3] - 1) - 1) // stride[1] + 1]
            builder.add_convolution(
                name, w.shape[1], w.shape[0], w.shape[2], w.shape[3], stride[0], stride[1], 'valid',
                attrs.get('group', 1), w.transpose(2, 3, 1, 0), b, b is not None,
                input_name=inputs[0], output_name=out, dilation_factors=attrs.get('dilations', [1, 1]),
                padding_top=pads[0], padding_left=pads[1], padding_bottom=pads[2], padding_right=pads[3],
            )
        elif node.op_type in ('Relu', 'Sigmoid'):
            known[node.output[0]] = known[node.input[0]]
            builder.add_activation(name, 'RELU' if node.op_type == 'Relu' else 'SIGMOID', inputs[0], out)
        elif node.op_type == 'Add':
            require(known[node.input[0]] == known[node.input[1]], f'{name}: Add shapes differ')
            known[node.output[0]] = known[node.input[0]]
            builder.add_elementwise(name, inputs, out, 'ADD')
        elif node.op_type == 'Concat':
            require(attrs['axis'] == 1, f'{name}: only channel concatenation is supported')
            parts = [known[value] for value in node.input]
            known[node.output[0]] = [parts[0][0], sum(p[1] for p in parts)] + parts[0][2:]
            builder.add_concat_nd(name, inputs, out, attrs['axis'])
        elif node.op_type == 'Resize':
            # PyTorch's bilinear upsampling without aligned corners, to a size fixed by the input's.
            require(
                attrs.get('mode') == b'linear' and attrs.get('coordinate_transformation_mode') in (b'pytorch_half_pixel', b'half_pixel'),
                f'{name}: Resize must be half-pixel bilinear',
            )
            require(len(node.input) > 3 and node.input[3] in constants, f'{name}: Resize needs a constant size')
            source_shape, target_shape = known[node.input[0]], [int(v) for v in constants[node.input[3]]]
            require(target_shape[:2] == source_shape[:2], f'{name}: Resize may change only the spatial size')
            known[node.output[0]] = target_shape
            builder.add_upsample(
                name, target_shape[2] / source_shape[2], target_shape[3] / source_shape[3], inputs[0], out,
                mode='BILINEAR', linear_upsample_mode='ALIGN_CORNERS_FALSE',
            )
        elif node.op_type == 'MaxPool':
            k = attrs['kernel_shape']
            stride = attrs.get('strides', [1, 1])
            require(list(attrs.get('pads', [0] * 4)) == [0] * 4, f'{name}: MaxPool padding is unsupported')
            n, c, h, w_ = known[node.input[0]]
            ceil = attrs.get('ceil_mode', 0)
            def pooled(size, kernel, step): return -(-(size - kernel) // step) + 1 if ceil else (size - kernel) // step + 1
            known[node.output[0]] = [n, c, pooled(h, k[0], stride[0]), pooled(w_, k[1], stride[1])]
            # Ceil mode keeps a last partial window, which is what Core ML's INCLUDE_LAST_PIXEL does.
            builder.add_pooling(
                name, k[0], k[1], stride[0], stride[1], 'MAX',
                'INCLUDE_LAST_PIXEL' if attrs.get('ceil_mode', 0) else 'VALID', inputs[0], out,
            )
        else:
            raise ValueError(f'Unsupported dynamic operator: {node.op_type}')
        retained[node.op_type] += 1
    require(known.get(FUSED_OUTPUT) == output_shape, f'Fused output has shape {known.get(FUSED_OUTPUT)}, expected {output_shape}')
    builder.spec.description.metadata.shortDescription = (
        'U²-Net sky segmentation by xiongzhu666, converted for Ceviche; upstream MIT license applies.'
    )
    builder.spec.description.metadata.userDefined['upstream'] = 'https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing'
    # Half-precision weights halve the download; MODELS.md records the difference this makes.
    half = quantize_weights(ct.models.MLModel(builder.spec, skip_model_load=True), nbits=16)
    ct.utils.save_spec(half.get_spec(), destination)
    print('Saved', destination, dict(retained))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('onnx')
    parser.add_argument('coreml')
    args = parser.parse_args()
    convert(args.onnx, args.coreml)
