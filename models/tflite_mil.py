"""TFLite graphs to Core ML programs, operator by operator, for the MediaPipe models Ceviche converts.

Each TFLite operator a model uses is mapped to its Core ML (MIL) equivalent and any other is refused, so a new
operator shows up as an error rather than a wrong result. Tensors keep TFLite's channels-last layout; convolutions,
pooling and resizes are wrapped in transposes, which the Core ML optimizer folds away. Half-precision weights
(DEQUANTIZE) are read as constants.
"""
import numpy as np
import tflite
from coremltools.converters.mil import Builder as mb

OPS = {getattr(tflite.BuiltinOperator, k): k for k in dir(tflite.BuiltinOperator) if not k.startswith("_")}
NCHW, NHWC = [0, 3, 1, 2], [0, 2, 3, 1]


def options(op, cls):
    table = op.BuiltinOptions()
    o = cls()
    o.Init(table.Bytes, table.Pos)
    return o


class Graph:
    def __init__(self, path):
        self.model = tflite.Model.GetRootAsModel(open(path, "rb").read(), 0)
        self.graph = self.model.Subgraphs(0)

    @property
    def input(self):
        return self.graph.Inputs(0)

    def output(self, k):
        return self.graph.Outputs(k)

    def shape(self, index):
        return [int(s) for s in self.graph.Tensors(index).ShapeAsNumpy()]

    def const(self, index):
        t = self.graph.Tensors(index)
        data = self.model.Buffers(t.Buffer()).DataAsNumpy()
        if isinstance(data, int) or data.size == 0:
            return None
        dtype = {tflite.TensorType.FLOAT32: np.float32, tflite.TensorType.FLOAT16: np.float16, tflite.TensorType.INT32: np.int32}[t.Type()]
        return np.frombuffer(data.tobytes(), dtype=dtype).reshape(t.ShapeAsNumpy())

    def build(self, values):
        """Adds every operator to the MIL program being built; `values` maps tensor index to MIL variable and must hold
        the graph's input. Returns `values` with every operator's output."""
        graph = self.graph

        def get(index):
            if index not in values:
                c = self.const(index)
                values[index] = c.astype(np.float32) if c is not None and c.dtype == np.float16 else c
            return values[index]

        def activate(x, function):
            if function == tflite.ActivationFunctionType.NONE:
                return x
            if function == tflite.ActivationFunctionType.RELU:
                return mb.relu(x=x)
            if function == tflite.ActivationFunctionType.RELU6:
                return mb.clip(x=x, alpha=0.0, beta=6.0)
            raise SystemExit(f"Unsupported fused activation {function}")

        def padding(p):
            return "same" if p == tflite.Padding.SAME else "valid"

        def nchw(index):
            return mb.transpose(x=get(index), perm=NCHW)

        for i in range(graph.OperatorsLength()):
            op = graph.Operators(i)
            code = self.model.OperatorCodes(op.OpcodeIndex())
            name = OPS[max(code.BuiltinCode(), code.DeprecatedBuiltinCode())]
            ins, out = list(op.InputsAsNumpy()), op.Outputs(0)
            if name == "DEQUANTIZE":
                c = self.const(ins[0])
                if c is None:
                    raise SystemExit(f"DEQUANTIZE of a computed tensor (#{i})")
                values[out] = c.astype(np.float32)
                continue
            if name == "CONV_2D":
                o = options(op, tflite.Conv2DOptions)
                y = mb.conv(x=nchw(ins[0]), weight=get(ins[1]).transpose(0, 3, 1, 2), bias=get(ins[2]), strides=[o.StrideH(), o.StrideW()],
                            dilations=[o.DilationHFactor(), o.DilationWFactor()], pad_type=padding(o.Padding()))
                y = mb.transpose(x=activate(y, o.FusedActivationFunction()), perm=NHWC)
            elif name == "DEPTHWISE_CONV_2D":
                o = options(op, tflite.DepthwiseConv2DOptions)
                weight = get(ins[1])  # 1 × H × W × C
                if o.DepthMultiplier() not in (0, 1):
                    raise SystemExit("Unsupported depth multiplier")
                y = mb.conv(x=nchw(ins[0]), weight=weight.transpose(3, 0, 1, 2), bias=get(ins[2]), groups=weight.shape[3],
                            strides=[o.StrideH(), o.StrideW()], dilations=[o.DilationHFactor(), o.DilationWFactor()],
                            pad_type=padding(o.Padding()))
                y = mb.transpose(x=activate(y, o.FusedActivationFunction()), perm=NHWC)
            elif name == "TRANSPOSE_CONV":
                o = options(op, tflite.TransposeConvOptions)
                shape = self.const(ins[0])
                weight = get(ins[1]).transpose(3, 0, 1, 2)  # O H W I → I O H W
                bias = get(ins[3]) if len(ins) > 3 and ins[3] >= 0 else None
                y = mb.conv_transpose(x=nchw(ins[2]), weight=weight, bias=bias, strides=[o.StrideH(), o.StrideW()],
                                      pad_type=padding(o.Padding()), output_shape=[int(shape[0]), int(shape[3]), int(shape[1]), int(shape[2])])
                y = mb.transpose(x=activate(y, o.FusedActivationFunction()), perm=NHWC)
            elif name == "MAX_POOL_2D":
                o = options(op, tflite.Pool2DOptions)
                y = mb.max_pool(x=nchw(ins[0]), kernel_sizes=[o.FilterHeight(), o.FilterWidth()], strides=[o.StrideH(), o.StrideW()],
                                pad_type=padding(o.Padding()))
                y = mb.transpose(x=activate(y, o.FusedActivationFunction()), perm=NHWC)
            elif name == "PAD":
                pads = self.const(ins[1])
                y = mb.pad(x=get(ins[0]), pad=[int(p) for p in pads.reshape(-1)], mode="constant", constant_val=0.0)
            elif name == "PRELU":
                x, alpha = get(ins[0]), get(ins[1])
                y = mb.add(x=mb.relu(x=x), y=mb.mul(x=alpha, y=mb.minimum(x=x, y=np.float32(0))))
            elif name == "LOGISTIC":
                y = mb.sigmoid(x=get(ins[0]))
            elif name in ("ADD", "MUL"):
                o = options(op, tflite.AddOptions if name == "ADD" else tflite.MulOptions)
                a, b = get(ins[0]), get(ins[1])
                y = activate(mb.add(x=a, y=b) if name == "ADD" else mb.mul(x=a, y=b), o.FusedActivationFunction())
            elif name == "RESHAPE":
                y = mb.reshape(x=get(ins[0]), shape=self.shape(out))
            elif name == "TRANSPOSE":
                y = mb.transpose(x=get(ins[0]), perm=[int(p) for p in self.const(ins[1])])
            elif name == "SOFTMAX":
                o = options(op, tflite.SoftmaxOptions)
                x = get(ins[0])
                if o.Beta() != 1.0:
                    x = mb.mul(x=x, y=np.float32(o.Beta()))
                y = mb.softmax(x=x, axis=-1)
            elif name == "SUM":
                o = options(op, tflite.ReducerOptions)
                y = mb.reduce_sum(x=get(ins[0]), axes=[int(a) for a in np.atleast_1d(self.const(ins[1]))], keep_dims=bool(o.KeepDims()))
            elif name in ("RESIZE_BILINEAR", "RESIZE_NEAREST_NEIGHBOR"):
                size = [int(s) for s in self.const(ins[1])]
                x = nchw(ins[0])
                if name == "RESIZE_BILINEAR":
                    o = options(op, tflite.ResizeBilinearOptions)
                    mode = "ALIGN_CORNERS" if o.AlignCorners() else "UNALIGN_CORNERS" if o.HalfPixelCenters() else "DEFAULT"
                    y = mb.resize_bilinear(x=x, target_size_height=size[0], target_size_width=size[1], sampling_mode=mode)
                else:
                    shape = self.shape(ins[0])
                    sh, sw = size[0] // shape[1], size[1] // shape[2]
                    if sh * shape[1] != size[0] or sw * shape[2] != size[1]:
                        raise SystemExit("Nearest resize by a non-integer factor")
                    y = mb.upsample_nearest_neighbor(x=x, scale_factor_height=sh, scale_factor_width=sw)
                y = mb.transpose(x=y, perm=NHWC)
            else:
                raise SystemExit(f"Unsupported operator {name} (#{i})")
            values[out] = y
        return values
