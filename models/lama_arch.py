# Big-LaMa generator for inference, following advimman/lama (saicinpainting/training/modules/ffc.py) @ 786f5936.
# Copyright (c) 2021 Samsung Research. Apache-2.0; see licenses/LaMa-LICENSE.
# Only what the big-lama configuration uses: no local Fourier unit, squeeze-excitation, gates or spatial transforms.
import torch
import torch.nn as nn


class FourierUnit(nn.Module):
    def __init__(self, in_channels, out_channels):
        super().__init__()
        self.conv_layer = nn.Conv2d(in_channels * 2, out_channels * 2, kernel_size=1, bias=False)
        self.bn = nn.BatchNorm2d(out_channels * 2)
        self.relu = nn.ReLU(inplace=True)

    # Shapes come from flatten/unflatten rather than x.shape, which tracing would record as tensors. Sides are even, so
    # the inverse transform's default width is the input's.
    def forward(self, x):
        ffted = torch.fft.rfftn(x, dim=(-2, -1), norm="ortho")
        ffted = torch.stack((ffted.real, ffted.imag), dim=2).flatten(1, 2)  # (batch, c*2, h, w/2+1), real and imaginary interleaved
        ffted = self.relu(self.bn(self.conv_layer(ffted))).unflatten(1, (-1, 2))
        return torch.fft.irfftn(torch.complex(ffted[:, :, 0], ffted[:, :, 1]), dim=(-2, -1), norm="ortho")


class SpectralTransform(nn.Module):
    def __init__(self, in_channels, out_channels):
        super().__init__()
        self.conv1 = nn.Sequential(nn.Conv2d(in_channels, out_channels // 2, kernel_size=1, bias=False),
                                   nn.BatchNorm2d(out_channels // 2), nn.ReLU(inplace=True))
        self.fu = FourierUnit(out_channels // 2, out_channels // 2)
        self.conv2 = nn.Conv2d(out_channels // 2, out_channels, kernel_size=1, bias=False)

    def forward(self, x):
        x = self.conv1(x)
        return self.conv2(x + self.fu(x))


class FFC(nn.Module):
    """Local (spatial) and global (spectral) channel groups, each fed by both."""
    def __init__(self, in_channels, out_channels, kernel_size, ratio_gin, ratio_gout, stride=1, padding=0, dilation=1):
        super().__init__()
        in_cg = int(in_channels * ratio_gin); in_cl = in_channels - in_cg
        out_cg = int(out_channels * ratio_gout); out_cl = out_channels - out_cg
        self.ratio_gout = ratio_gout
        self.global_in_num = in_cg

        def conv(i, o):
            return nn.Conv2d(i, o, kernel_size, stride, padding, dilation, bias=False, padding_mode="reflect") if i and o else None
        self.convl2l, self.convl2g, self.convg2l = conv(in_cl, out_cl), conv(in_cl, out_cg), conv(in_cg, out_cl)
        self.convg2g = SpectralTransform(in_cg, out_cg) if in_cg and out_cg else None

    def forward(self, x_l, x_g):
        out_l = out_g = None
        if self.ratio_gout != 1:
            out_l = self.convl2l(x_l)
            if self.convg2l is not None: out_l = out_l + self.convg2l(x_g)
        if self.ratio_gout != 0:
            out_g = self.convl2g(x_l)
            if self.convg2g is not None: out_g = out_g + self.convg2g(x_g)
        return out_l, out_g


class FFC_BN_ACT(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, ratio_gin, ratio_gout, stride=1, padding=0, dilation=1):
        super().__init__()
        self.ffc = FFC(in_channels, out_channels, kernel_size, ratio_gin, ratio_gout, stride, padding, dilation)
        global_channels = int(out_channels * ratio_gout)
        self.bn_l = nn.BatchNorm2d(out_channels - global_channels) if ratio_gout != 1 else nn.Identity()
        self.bn_g = nn.BatchNorm2d(global_channels) if ratio_gout != 0 else nn.Identity()
        self.act = nn.ReLU(inplace=True)

    def forward(self, x_l, x_g=None):
        out_l, out_g = self.ffc(x_l, x_g)
        return (self.act(self.bn_l(out_l)) if out_l is not None else None,
                self.act(self.bn_g(out_g)) if out_g is not None else None)


class FFCResnetBlock(nn.Module):
    def __init__(self, dim, ratio):
        super().__init__()
        self.conv1 = FFC_BN_ACT(dim, dim, 3, ratio, ratio, padding=1)
        self.conv2 = FFC_BN_ACT(dim, dim, 3, ratio, ratio, padding=1)

    def forward(self, x_l, x_g):
        y_l, y_g = self.conv1(x_l, x_g)
        y_l, y_g = self.conv2(y_l, y_g)
        return x_l + y_l, x_g + y_g


class FFCResNetGenerator(nn.Module):
    """big-lama: input_nc 4 (masked RGB and mask), ngf 64, 3 downsamplings, 18 blocks, 0.75 of the bottleneck global."""
    def __init__(self, input_nc=4, output_nc=3, ngf=64, n_downsampling=3, n_blocks=18, ratio=0.75):
        super().__init__()
        self.pad_in = nn.ReflectionPad2d(3)
        self.init = FFC_BN_ACT(input_nc, ngf, 7, 0, 0)
        self.down = nn.ModuleList(
            FFC_BN_ACT(ngf * 2 ** i, ngf * 2 ** (i + 1), 3, 0, ratio if i == n_downsampling - 1 else 0, stride=2, padding=1)
            for i in range(n_downsampling))
        features = ngf * 2 ** n_downsampling
        self.blocks = nn.ModuleList(FFCResnetBlock(features, ratio) for _ in range(n_blocks))
        up = []
        for i in range(n_downsampling):
            channels = ngf * 2 ** (n_downsampling - i)
            up += [nn.ConvTranspose2d(channels, channels // 2, kernel_size=3, stride=2, padding=1, output_padding=1),
                   nn.BatchNorm2d(channels // 2), nn.ReLU(True)]
        self.up = nn.Sequential(*up, nn.ReflectionPad2d(3), nn.Conv2d(ngf, output_nc, kernel_size=7), nn.Sigmoid())

    def forward(self, x):
        x_l, _ = self.init(self.pad_in(x))
        x_g = None
        for layer in self.down:
            x_l, x_g = layer(x_l, x_g)
        for block in self.blocks:
            x_l, x_g = block(x_l, x_g)
        return self.up(torch.cat((x_l, x_g), dim=1))

    @torch.no_grad()
    def fold_batch_norms(self):
        """Folds every batch norm into the convolutions summed before it, which is exact in inference. Unfolded, the local
        branch's sums reach about 1.1e5 on smooth areas at 1024 px before their batch norm scales them down, past
        FP16's 65504."""
        def fold(convs, bn):
            scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
            for conv in convs:
                shape = (1, -1, 1, 1) if isinstance(conv, nn.ConvTranspose2d) else (-1, 1, 1, 1)
                conv.weight.mul_(scale.view(shape))
                if conv.bias is not None: conv.bias.mul_(scale)
            first = convs[0]
            shift = bn.bias - bn.running_mean * scale
            if first.bias is None: first.bias = nn.Parameter(shift.clone())
            else: first.bias.add_(shift)

        def fold_ffc(layer):
            ffc = layer.ffc
            if isinstance(layer.bn_l, nn.BatchNorm2d):
                fold([c for c in (ffc.convl2l, ffc.convg2l) if c is not None], layer.bn_l); layer.bn_l = nn.Identity()
            if isinstance(layer.bn_g, nn.BatchNorm2d):
                fold([c for c in (ffc.convl2g, ffc.convg2g.conv2 if ffc.convg2g is not None else None) if c is not None], layer.bn_g)
                layer.bn_g = nn.Identity()
            if ffc.convg2g is not None:
                spectral = ffc.convg2g
                fold([spectral.conv1[0]], spectral.conv1[1]); spectral.conv1[1] = nn.Identity()
                fold([spectral.fu.conv_layer], spectral.fu.bn); spectral.fu.bn = nn.Identity()

        fold_ffc(self.init)
        for layer in self.down: fold_ffc(layer)
        for block in self.blocks: fold_ffc(block.conv1); fold_ffc(block.conv2)
        for i in (0, 3, 6):
            fold([self.up[i]], self.up[i + 1]); self.up[i + 1] = nn.Identity()
        return self

    @staticmethod
    def remap(state):
        """Upstream keys are indices into one nn.Sequential (`generator.model.N.`); these are named stages."""
        names = {0: None, 1: "init", 2: "down.0", 3: "down.1", 4: "down.2"}
        names.update({5 + i: f"blocks.{i}" for i in range(18)})
        result = {}
        for key, value in state.items():
            if not key.startswith("generator.model."): continue
            index, rest = key[len("generator.model."):].split(".", 1)
            index = int(index)
            if index in names: result[f"{names[index]}.{rest}"] = value
            elif index >= 24: result[f"up.{index - 24}.{rest}"] = value
            else: raise KeyError(key)
        return result
