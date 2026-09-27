# Configurable NPU Convolution Accelerator on Zynq-7000

[![checks](https://github.com/h23yonsei/npu-conv-accelerator-pynq/actions/workflows/checks.yml/badge.svg)](https://github.com/h23yonsei/npu-conv-accelerator-pynq/actions/workflows/checks.yml)

A configurable convolution accelerator (NPU) for the PYNQ-Z2 (Zynq-7020): a single-MAC datapath
driven over AXI4-Lite CSRs, with block-RAM-resident IFM, weight and OFM tiles, and a Python golden
model the RTL is checked against. Driven through its CSRs in simulation, the packaged IP matches the
golden model on all 5,742 output words of five tiles, and it meets timing at 50 MHz in 12 % of the
device's LUTs.

Built during the ISL internship program at Yonsei University over the summer of 2025, following
EEE3551 Intelligent System Design and Applications. The program provided the task specification
(the tiled convolution loop nest the hardware implements and an example CSR layout) and the CNN
weights and test images in `data/`. The RTL, the golden model and testbench, the block design,
and the build and verification scripts were written for the project.

## Architecture

```text
              ZYNQ7 Processing System
              (M_AXI_GP0, FCLK_CLK0)
                         |
                  AXI SmartConnect
            _____|____|____|______
           |          |    |     |
     AXI BRAM    AXI BRAM  AXI BRAM   npu_top (S_AXI)
     Ctrl IFM    Ctrl WGT  Ctrl OFM   ├── npu_csr_axil (CSR)
        |           |         |       └── conv_engine (MAC datapath)
     BMG IFM     BMG WGT   BMG OFM
     (64KB)      (128KB)   (256KB)
      Port B ──── npu_top ──── Port B
```

The PS writes IFM and weight tiles into the BRAMs through AXI BRAM controllers, configures the
convolution through four CSRs (`CTRL`, `STATUS`, `CFG_A`, `CFG_B`) and pulses `start`. The
`conv_engine` FSM computes one output tile with a single multiply-accumulate datapath (the
six-loop convolution) and raises `done` when the OFM BRAM is ready to read back.

## Repository structure

```text
├── rtl/                        # RTL (SystemVerilog), packaged as the npu_top IP
│   ├── npu_top.sv              # Top level: AXI4-Lite slave + three BRAM port-B interfaces
│   ├── conv_engine.sv          # Single-MAC convolution datapath FSM
│   ├── npu_csr_axil.sv         # AXI4-Lite CSR slave
│   ├── component.xml, xgui/    # Vivado IP packaging
│   └── tb/                     # Testbenches (conv_engine, npu_top), generated configs, vectors
├── golden_model/
│   ├── conv2d.py               # conv2d_6for / conv2d_9for, LeakyReLU, max pooling, FC
│   ├── test_conv2d.py          # tiled vs naive convolution equivalence
│   └── run_network.py          # full four-layer CNN on the test images
├── tools/
│   ├── run_sims.py             # every verification check, one command
│   ├── gen_tb_vectors.py       # testbench vectors from the golden model
│   └── build.tcl               # synthesis, implementation, bitstream, .hwh, .xsa, reports
├── docs/
│   ├── register_map.md         # CSR register map and PYNQ driver example
│   ├── block_design.md         # the Vivado block design, step by step
│   └── block_design.tcl        # Tcl scaffold that recreates the block design
├── reports/                    # utilization and timing reports from tools/build.tcl
├── data/                       # CNN weights and test data (.npy), provided by the program
└── vivado/                     # Vivado project: npu.xpr, block design (.bd) and IP configs (.xci)
```

## Network pipeline

The CNN the program specified (stride 1, no padding, int8 weights and input images):

| Layer | Shape | Output |
|-------|-------|--------|
| Conv1 | (8, 1, 3, 3) | (8, 26, 26) |
| Conv2 | (16, 8, 3, 3) | (16, 24, 24) |
| Conv3 | (64, 16, 3, 3) | (64, 22, 22) |
| Conv4 | (128, 64, 3, 3) | (128, 20, 20) |
| MaxPool | 2x2 | (128, 10, 10) |
| FC | (12800, 10) | (10,) |

The NPU computes one int8 × int8 → int32 convolution tile per `start`. `run_network.py` runs the
four convolution layers in exact integer arithmetic, with LeakyReLU (slope 1/16) between them and
no requantization, so the activations grow from 8 bits at the input to 17 bits after Conv1 and 42
bits after Conv4 (test image 0). It validates the network definition and the tiled loop nest, not a
run on the NPU: the NPU reads int8 activations and accumulates in 32 bits, so Conv2–Conv4 would
need each layer's output requantized to int8 on the PS first, which this repository does not
implement. Conv1, whose input is the int8 image, runs on the NPU as it is: `tb_npu_top` computes the
whole layer for test image 0 as one 26×26×8 tile and matches the golden model.

## Verification

```bash
pip install -r requirements.txt
python tools/run_sims.py --vivado C:/Xilinx/Vivado/2022.1   # Vivado's simulator
python tools/run_sims.py --sim verilator                    # Verilator 5 instead
python tools/run_sims.py --skip-hdl                         # the Python checks only
```

Without `--vivado` or `--sim`, Vivado is used if it is installed and Verilator otherwise.

| Check | Result |
| --- | --- |
| Golden model: `conv2d_9for` (tiled) vs `conv2d_6for` (`golden_model/test_conv2d.py`) | all 5 equivalence cases match |
| Golden model, full four-layer network on the first 20 test images (`run_network.py`) | 19 / 20 correct; agrees with the float reference `output.npy` on 19 / 20 |
| Test vectors (`tools/gen_tb_vectors.py`) | all 20 committed vector and config files match a fresh regeneration |
| `conv_engine` vs golden model (`rtl/tb/tb_conv_engine.sv`): one tile, 2 → 2 channels, 3×3 kernel, 4×4 tile | **PASS**: all 32 OFM words match |
| `npu_top` vs golden model (`rtl/tb/tb_npu_top.sv`): five tiles through the AXI4-Lite CSRs, with the block RAMs' port B modeled as the block design configures it | **PASS**: all 5,742 OFM words match |

All five checks pass with Verilator, which the repository runs on every push (the badge above),
and in Vivado 2022.1's simulator; both HDL testbenches also pass in Icarus Verilog 12 via sv2v. The
testbenches change their inputs 1 ns after the clock edge, so no result depends on a simulator's
event order.

The one disagreement is image 18, a near-tie in the floating-point reference (logits 70 vs 67 for
classes 3 and 2) that the integer model resolves the other way: a quantization effect, not an RTL
error. The network check runs the loop-level golden model in pure Python and takes several minutes.

`tb_npu_top` drives the packaged IP the way the PS driver in
[`docs/register_map.md`](docs/register_map.md) does: it fills the IFM and WEIGHT memories four
bytes per word, writes `CFG_A` and `CFG_B` and reads them back, writes `CTRL` = 1 then 0, polls
`STATUS` until `done`, and compares the OFM. Its five tiles are the whole Conv1 layer on test image
0 (a 26×26 tile of 8 channels), a 5×7 tile at stride 2, a 2×4 kernel at stride 3, a 1×1 kernel
over 16 channels, and 64 channels of −128 against weights of −128 and 127, the largest sums in
either direction (±9.4 million). It also checks that `done` reads 0 after reset and is cleared by
every new start, and that nothing is written past the end of a tile.

**Block RAM port B.** Because an AXI BRAM Controller drives port A, IP Integrator puts each block
RAM in BRAM Controller mode, where port B also takes a 32-bit byte address (the memory ignores its
two low bits) and one write enable per byte. `npu_top` drives port B that way, and the testbench
models port B exactly as the block design configures it: against that model, a port B driven with
word addresses and a single write enable fails all 5,742 OFM words.

## Implementation results

Vivado 2022.1, post-route, `npu_bd_wrapper` on `xc7z020clg400-1`, with no black boxes; the raw
reports are in [`reports/`](reports/). The design has not been run on a board: everything below
comes from implementation reports and simulation.

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| LUT | 6,507 | 53,200 | 12.23 % |
| — as logic | 5,596 | 53,200 | 10.52 % |
| — as memory | 911 | 17,400 | 5.24 % |
| Flip-flops | 6,599 | 106,400 | 6.20 % |
| Block RAM (RAMB36E1) | 112 | 140 | 80.00 % |
| DSP48 | 10 | 220 | 4.55 % |

| Timing | Value |
| --- | --- |
| Clock | `clk_fpga_0`, 50 MHz from PS `FCLK_CLK0` |
| Setup | **met**: WNS +4.529 ns, 0 of 27,649 endpoints failing |
| Hold | met: WHS +0.020 ns |
| Implied Fmax | ≈ 64.6 MHz |

The single-MAC datapath is deliberately small in logic (12 % of the LUTs, 10 DSPs), and the cost
sits almost entirely in memory: the three IFM, weight and OFM tile BRAMs take 80 % of the device's
block RAM. That is the expected shape for this design point, and it is the constraint any wider
MAC array would run into first on a 7020. The critical path runs from the weight block RAM through
`conv_engine`'s multiply-accumulate logic into its accumulator (14.9 ns over 14 logic levels, 8 of
them carry chain, 56 % of the delay in routing), and it limits the design to the ≈ 64.6 MHz above.

## Building it

```bash
vivado -mode batch -nojournal -source tools/build.tcl
```

The script opens `vivado/npu.xpr`, points the IP catalog at `rtl/`, regenerates the block design,
synthesizes and implements it in fresh runs, and writes `build/npu.bit`, `build/npu.hwh` (the
hardware handoff PYNQ loads with the bitstream), `build/npu.xsa` (bitstream included) and the
reports in `reports/`.

To recreate the block design from scratch instead of using the committed project, follow
[`docs/block_design.md`](docs/block_design.md) or source `docs/block_design.tcl`.

To run it on a PYNQ-Z2, copy `build/npu.bit` and `build/npu.hwh` to one directory on the board,
load the bitstream as an overlay and access the regions as `MMIO`:

```python
from pynq import Overlay, MMIO

ol = Overlay("npu.bit")
CSR    = MMIO(0x4000_0000, 0x1000)
IFM    = MMIO(0x4001_0000, 0x10000)
WEIGHT = MMIO(0x4002_0000, 0x20000)
OFM    = MMIO(0x4004_0000, 0x40000)

# See docs/register_map.md for the full driver API
```

## CSR register map

| Register | Offset | Description |
|----------|--------|-------------|
| CTRL | 0x00 | `[0]` start pulse |
| STATUS | 0x04 | `[0]` done flag (RO) |
| CFG_A | 0x08 | `[7:0]` input_ch, `[15:8]` output_ch, `[23:16]` kernel_h, `[31:24]` kernel_w |
| CFG_B | 0x0C | `[8:0]` tile_h, `[17:9]` tile_w, `[20:18]` stride |

## Requirements

- **Vivado** 2022.1 (simulation, synthesis and implementation); the simulations also run in
  **Verilator** 5
- **Python** 3.8+ with NumPy (`requirements.txt`)
- **Target board**: PYNQ-Z2 (Zynq XC7Z020)

## License

Released under the [MIT License](LICENSE). The program-provided data in `data/` remains the
program's.
