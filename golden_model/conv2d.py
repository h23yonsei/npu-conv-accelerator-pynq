"""Golden model for the configurable NPU convolution core.

Both conv2d_6for and conv2d_9for implement the exact same mathematical
operation; conv2d_9for additionally tiles the computation along
(output_h, output_w, output_ch), and its inner loop over one tile is what the
NPU (rtl/conv_engine.sv) computes for each start.
"""

import numpy as np


def conv2d_6for(i_act, weight, stride=1):
    # i_act: (input_ch, input_h, input_w)
    # weight: (output_ch, input_ch, kernel_h, kernel_w)
    input_ch, input_h, input_w = i_act.shape
    output_ch, _, kernel_h, kernel_w = weight.shape

    output_h = (input_h - kernel_h) // stride + 1
    output_w = (input_w - kernel_w) // stride + 1
    o_act = np.zeros((output_ch, output_h, output_w), dtype=np.int64)

    for oc in range(output_ch):
        for oh in range(output_h):
            h_start = oh * stride
            for ow in range(output_w):
                w_start = ow * stride
                temp = 0
                for ic in range(input_ch):
                    for kh in range(kernel_h):
                        for kw in range(kernel_w):
                            val = i_act[ic, h_start + kh, w_start + kw]
                            wgt = weight[oc, ic, kh, kw]
                            temp += int(val) * int(wgt)
                o_act[oc, oh, ow] = temp
    return o_act


def conv2d_9for(i_act, weight, stride=1, tile_h=8, tile_w=8, tile_oc=8):
    # i_act: (input_ch, input_h, input_w)
    # weight: (output_ch, input_ch, kernel_h, kernel_w)
    input_ch, input_h, input_w = i_act.shape
    output_ch, _, kernel_h, kernel_w = weight.shape

    output_h = (input_h - kernel_h) // stride + 1
    output_w = (input_w - kernel_w) // stride + 1
    o_act = np.zeros((output_ch, output_h, output_w), dtype=np.int64)

    for oh in range(0, output_h, tile_h):
        for ow in range(0, output_w, tile_w):
            for oc in range(0, output_ch, tile_oc):
                h_range = min(tile_h, output_h - oh)
                w_range = min(tile_w, output_w - ow)
                oc_range = min(tile_oc, output_ch - oc)
                tile_o_act = np.zeros((oc_range, h_range, w_range), dtype=np.int64)

                for toc in range(oc_range):
                    for toh in range(h_range):
                        h_start = (oh + toh) * stride
                        for tow in range(w_range):
                            w_start = (ow + tow) * stride
                            temp = 0
                            for ic in range(input_ch):
                                for kh in range(kernel_h):
                                    for kw in range(kernel_w):
                                        val = i_act[ic, h_start + kh, w_start + kw]
                                        wgt = weight[oc + toc, ic, kh, kw]
                                        temp += int(val) * int(wgt)
                            tile_o_act[toc, toh, tow] = temp

                o_act[oc:oc + oc_range, oh:oh + h_range, ow:ow + w_range] = tile_o_act
    return o_act


def leaky_relu(x, shamt=4):
    """Leaky ReLU with a shift-based negative slope (x >> shamt for x < 0).

    The default shamt of 4 gives a slope of 1/16. The NPU does not implement
    the activation: it returns raw int32 sums, and this runs on the PS.
    """
    return np.where(x >= 0, x, x >> shamt)


def maxpool2d(x, pool=2, stride=2):
    # x: (ch, h, w)
    ch, h, w = x.shape
    out_h = (h - pool) // stride + 1
    out_w = (w - pool) // stride + 1
    out = np.zeros((ch, out_h, out_w), dtype=x.dtype)

    for oh in range(out_h):
        h_start = oh * stride
        for ow in range(out_w):
            w_start = ow * stride
            out[:, oh, ow] = x[:, h_start:h_start + pool, w_start:w_start + pool].max(axis=(1, 2))
    return out


def fc_layer(x, weight):
    # x: any shape, flattened to (in_features,)
    # weight: (out_features, in_features)
    x_flat = x.reshape(-1).astype(np.int64)
    return weight.astype(np.int64) @ x_flat
