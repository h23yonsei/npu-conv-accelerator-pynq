# NPU Configurable Controller — CSR Register Map

AXI4-Lite slave, 32-bit registers, 4-byte address stride (standard AXI4-Lite
peripheral layout). Implemented in `rtl/npu_csr_axil.sv`.

## Hardware contract

Each `start` pulse computes **one output tile** of `conv2d_9for`'s inner loop:

```python
for toc in range(oc_range):       # output_ch
    for toh in range(tile_h):     # H_range
        for tow in range(tile_w): # W_range
            temp = 0
            for ic in range(input_ch):
                for kh in range(kernel_h):
                    for kw in range(kernel_w):
                        temp += ifm[ic, toh*stride+kh, tow*stride+kw] * weight[toc, ic, kh, kw]
            ofm[toc, toh, tow] = temp
```

Before pulsing `start`, the PS must write into the IFM/WEIGHT BRAMs exactly:

- **IFM window**: `input_ch x ((tile_h-1)*stride+kernel_h) x ((tile_w-1)*stride+kernel_w)`
  int8 values, row-major `[ic][h][w]`
- **WEIGHT tile**: `oc_range x input_ch x kernel_h x kernel_w` int8 values,
  row-major `[toc][ic][kh][kw]`

After `done` is asserted, the OFM BRAM holds `oc_range x tile_h x tile_w`
int32 values, row-major `[toc][toh][tow]`.

All three memories are 32 bits wide. In the IFM and WEIGHT BRAMs, int8 value
`k` of the order above is byte `k % 4` of word `k // 4` (bits
`[8*(k%4)+7 : 8*(k%4)]`), which is the layout a little-endian CPU produces when
it copies an int8 array into the region byte for byte. In the OFM BRAM, value
`m` is the whole of word `m`, at byte offset `4*m`.

All address strides for IFM/WEIGHT/OFM are derived inside `conv_engine.sv`
purely from the fields below — no extra "shape" registers are needed.

## Registers

| Name   | Offset | Access | Bits     | Field           | Description |
|--------|--------|--------|----------|-----------------|-------------|
| CTRL   | 0x00   | RW     | [0]      | `start`         | Write 1 then 0 (pulse) to begin computing one tile. |
|        |        |        | [31:1]   | Reserved        | |
| STATUS | 0x04   | RO     | [0]      | `done`          | 1 = tile result valid in OFM BRAM. Cleared when `start` is next asserted. |
|        |        |        | [31:1]   | Reserved        | |
| CFG_A  | 0x08   | RW     | [7:0]    | `input_ch`      | IC |
|        |        |        | [15:8]   | `output_ch`     | oc_range (tile_oc) |
|        |        |        | [23:16]  | `kernel_h`      | KH |
|        |        |        | [31:24]  | `kernel_w`      | KW |
| CFG_B  | 0x0C   | RW     | [8:0]    | `tile_h`        | H_range |
|        |        |        | [17:9]   | `tile_w`        | W_range |
|        |        |        | [20:18]  | `stride`        | stride (1-7) |
|        |        |        | [31:21]  | Reserved        | |

## Mapping from the specification's example CSR

| Specification field | CSR field here          |
|---------------------|--------------------------|
| `core_start`        | CTRL.start |
| `core_status`       | STATUS.done |
| `input_ch[7:0]`      | CFG_A.input_ch |
| `oc_range[7:0]`      | CFG_A.output_ch |
| `Kernel_H[7:0]`      | CFG_A.kernel_h |
| `Kernel_W[7:0]`      | CFG_A.kernel_w |
| `H_range[7:0]`       | CFG_B.tile_h |
| `W_range[7:0]`       | CFG_B.tile_w |
| `stride[2:0]`        | CFG_B.stride |

The specification's example uses a 16-bit-per-address layout;
this design packs the same fields into 4 standard 32-bit AXI4-Lite
registers, which is what Vivado's "AXI4 Peripheral" IP template generates
by default (`slv_reg0..3`).

## Driver usage (Python/PYNQ)

```python
CTRL, STATUS, CFG_A, CFG_B = 0x00, 0x04, 0x08, 0x0C

def run_tile(npu, input_ch, output_ch, kernel_h, kernel_w, tile_h, tile_w, stride):
    cfg_a = input_ch | (output_ch << 8) | (kernel_h << 16) | (kernel_w << 24)
    cfg_b = tile_h | (tile_w << 9) | (stride << 18)
    npu.write(CFG_A, cfg_a)
    npu.write(CFG_B, cfg_b)
    npu.write(CTRL, 1)
    npu.write(CTRL, 0)
    while (npu.read(STATUS) & 0x1) == 0:
        pass
```
