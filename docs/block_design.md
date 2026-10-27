# Vivado Block Design

This is the IP Integrator wiring for `npu_top` (see `rtl/npu_top.sv`,
`rtl/conv_engine.sv`, `rtl/npu_csr_axil.sv`). Target board: PYNQ-Z2 (Zynq-7020).
The committed project in `vivado/` is this design; `tools/build.tcl` builds it.

```text
                 ZYNQ7 Processing System
                 (M_AXI_GP0, FCLK_CLK0, FCLK_RESET0_N)
                              |
                         AXI SmartConnect
                 ____________/   |   |   \____________
                |                |   |                |
        AXI BRAM Ctrl0     AXI BRAM Ctrl1  AXI BRAM Ctrl2   npu_top.S_AXI
           (IFM, Port A)     (WEIGHT, A)     (OFM, A)       (CSR: CTRL/STATUS/
                |                |              |            CFG_A/CFG_B)
        BMG: IFM BRAM       BMG: WEIGHT     BMG: OFM BRAM        |
        (True Dual Port)    BRAM (TDP)      (TDP)                |
           Port B ------------------------------------------ npu_top
           Port B ------------------------------------------ (conv_engine
           Port B ------------------------------------------  native ports)
```

## 1. Package `npu_top` as an IP

`rtl/` already holds the packaged IP (`rtl/component.xml`): to use it, add `rtl/` under
*Project Settings -> IP -> Repository* and go on to section 2. To package it again:

1. `Tools -> Create and Package New IP -> Package a specified directory`,
   point it at `rtl/` (containing `npu_csr_axil.sv`, `conv_engine.sv`,
   `npu_top.sv`).
2. In the IP packager:
   - **Identification**: name it e.g. `npu_top_v1_0`.
   - **Compatibility / File Groups**: verify all three `.sv` files are listed
     as synthesis + simulation sources, with `npu_top.sv` as the top.
   - **Ports and Interfaces**: click *Merge changes from File Groups Wizard*.
     - `s_axi_*` auto-infers as an `AXI4LITE` slave interface named `S_AXI`,
       clock `s_axi_aclk`, reset `s_axi_aresetn`.
     - `ifm_bram_*`, `wgt_bram_*`, `ofm_bram_*` do **not** get grouped into
       `BRAM_PORT` interfaces by the packager — each `*_bram_clk` instead
       becomes its own standalone clock interface (`ifm_bram_clk`,
       `wgt_bram_clk`, `ofm_bram_clk`), and `*_addr/_en/_we/_din/_dout` stay
       as plain ports. **This is fine — don't fight it.** Leave them as-is;
       the block design wires them at the signal level (see step 2f), and
       the three extra clock interfaces just give Connection Automation more
       things to tie to `FCLK_CLK0` (harmless, same clock domain as `S_AXI`).
   - **Review and Package**: package the IP into a local repo (e.g.
     `ip_repo/`), then add that repo under
     *Project Settings -> IP -> Repository*.

## 2. Create the block design

`Create Block Design` -> name it `npu_bd`.

### 2a. ZYNQ7 Processing System

- Add **ZYNQ7 Processing System** and run **Run Block Automation**. With the PYNQ-Z2 board files
  installed and the project's board part set to them, this applies the board's PS preset. The
  committed design does not have the preset: its PS keeps Vivado's default configuration, a
  33.333 MHz input clock, where the PYNQ-Z2 has 50 MHz, and a default DDR part. A PYNQ overlay is
  unaffected, since PYNQ's own boot configures the PS and the overlay loader applies the clock
  settings in `npu.hwh`; a standalone boot from `npu.xsa` would need the board preset first.
- In *Re-customize IP*, under **PS-PL Configuration**:
  - Enable **M_AXI_GP0** (AXI master from PS to PL — drives all CSR/BRAM
    controller accesses).
  - Set **FCLK_CLK0** to **50 MHz** (*Clock Configuration* -> *PL Fabric Clocks*). The committed
    design is implemented at 50 MHz: its longest path, from the weight block RAM through
    `conv_engine`'s multiply-accumulate logic into its accumulator, takes 14.9 ns and does not fit
    the 10 ns period of the 100 MHz default.

### 2b. Add `npu_top`

- Add the packaged `npu_top_v1_0` IP to the canvas.
- Leave its `S_AXI` and its 18 `*_bram_*` ports (six per memory) unconnected for now.

### 2c. Add the three BRAMs (Block Memory Generator, True Dual Port)

Add three **Block Memory Generator** IPs, each configured:
- **Memory Type**: `True Dual Port RAM`
- **Common Port Options**: `Use ENA/ENB pins`.
- Once step 2d connects an AXI BRAM Controller to port A, IP Integrator
  switches each BMG to **BRAM Controller** mode: the depth follows the
  controller's range in the Address Editor (step 2g), and both ports take a
  32-bit byte address and one write enable per byte (`Use Byte Write
  Enable`). Step 2f relies on this for port B.

| Instance      | Port A (PS side, via AXI BRAM Ctrl) | Port B (HW side, npu_top/conv_engine) | Total size |
|---------------|-------------------------------------|---------------------------------------|------------|
| `bram_ifm`    | 16,384 × 32-bit                     | 16,384 × 32-bit                       | 64 KB      |
| `bram_weight` | 32,768 × 32-bit                     | 32,768 × 32-bit                       | 128 KB     |
| `bram_ofm`    | 65,536 × 32-bit                     | 65,536 × 32-bit                       | 256 KB     |

Both ports same width and depth — this is BMG's default True Dual Port
config (no separate Port A/B width tabs needed). The NPU needs the largest
tile of the network — Conv4 as one tile: IFM 64×22×22 = 30,976 bytes, WEIGHT
128×64×3×3 = 73,728 bytes, OFM 128×20×20 int32 = 200 KB (see the parameter
comments in `rtl/conv_engine.sv`) — rounded up to power-of-two sizes: 32 KB,
128 KB and 256 KB. The IFM memory is 64 KB because its controller's range in
the committed address map is 64K; `npu_top` addresses its first 32 KB.

> **Why not an 8-bit port B for IFM/WEIGHT?** BMG True Dual Port RAM requires
> port B's width to be >= port A's width (1x/2x/4x only) — an 8-bit port B
> with a 32-bit port A is rejected by Vivado. `conv_engine` still reads
> IFM/WEIGHT as individual int8 bytes; `npu_top.sv` adapts this to the
> 32-bit port B with a small registered byte-select mux (see step 2f).

### 2d. Add AXI BRAM Controllers

Add three **AXI BRAM Controller** IPs (`axi_bram_ctrl_ifm`,
`axi_bram_ctrl_weight`, `axi_bram_ctrl_ofm`):
- **BRAM Instance**: `External` (the default), so each controller drives its own
  Block Memory Generator
- **Number of BRAM interfaces**: 1 (only port A is used here)
- Disable ECC.

Connect each controller's `BRAM_PORTA` to the corresponding BMG's `BRAM_PORTA`
(IP Integrator draws these as a direct `BRAM_PORT` connection — no
interconnect needed for this link).

### 2e. Wire AXI

- Run **Connect Automation** (or add an **AXI SmartConnect** manually) from `ZYNQ7 PS / M_AXI_GP0`
  to:
  - `axi_bram_ctrl_ifm.S_AXI`
  - `axi_bram_ctrl_weight.S_AXI`
  - `axi_bram_ctrl_ofm.S_AXI`
  - `npu_top.S_AXI`
- Connect all `ACLK`/`ARESETN` ports to `FCLK_CLK0` and to the `peripheral_aresetn` of a
  `proc_sys_reset` IP. Connect Automation usually does this and names the IP after the clock,
  `rst_ps7_0_50M` at 50 MHz; the committed design and `docs/block_design.tcl` name it
  `rst_ps7_0_100M` instead, and the name does not matter.

### 2f. Wire each BRAM's native port B to `npu_top`

Since `npu_top`'s `*_bram_*` ports are plain signals (not a `BRAM_PORT`
interface — see step 1), wire each one individually to the corresponding
BMG port B pin. On the BMG side, port B is *also* exposed as individual flat
pins (not a `BRAM_PORTB` bus interface), named with a `B` suffix:

For each of `bram_ifm`, `bram_weight`, `bram_ofm`, connect:

| `npu_top_0` pin | `bram_<x>` pin |
|-----------------|----------------|
| `<x>_bram_addr` | `ADDRB`        |
| `<x>_bram_clk`  | `CLKB`         |
| `<x>_bram_en`   | `ENB`          |
| `<x>_bram_we`   | `WEB`          |
| `<x>_bram_din`  | `DINB`         |
| `<x>_bram_dout` | `DOUTB`        |

(`<x>` = `ifm`, `wgt`/`weight`, `ofm`.)

`*_bram_din`/`*_bram_dout` are 32-bit on all three, matching `DINB`/`DOUTB`.
`*_bram_addr` is a 32-bit **byte address** and `*_bram_we` has one bit per
byte, the widths of `ADDRB` and `WEB` in BRAM Controller mode (step 2c), so
every pin connects at full width. The BMG ignores the two low address bits
and uses the ones above them as the word address; `npu_top` sets the low
bits to zero and selects the byte within each IFM/WEIGHT word itself. It
drives all four OFM write enables together, one int32 result per word, and
never writes the IFM and WEIGHT memories.

> **Why this matters.** A port B driven with a word address and a single
> write enable would connect to the low bits of `ADDRB` and `WEB`, so on
> hardware every port-B access would land on word `addr / 4`, and each OFM
> write would store only its low byte. `rtl/tb/tb_npu_top.sv` models port B
> the way the BMG decodes it; against that model, such a design fails all
> 5,742 OFM words.

`CLKB`: the BMGs keep their default independent port clocks, so each has a
`CLKB` pin, which takes `<x>_bram_clk`. `npu_top` drives that from
`s_axi_aclk`, so port B runs on `FCLK_CLK0`, like the AXI BRAM Controller on
port A.

This is exactly what `docs/block_design.tcl` does with `connect_bd_net` at
the pin level (no interface grouping required on either side).

### 2g. Address map

Open the **Address Editor** and assign the map of the committed design, which the PYNQ examples
in this repository use:

| Slave                  | Base address  | Range | Notes                                         |
|------------------------|---------------|-------|-----------------------------------------------|
| `npu_top / S_AXI`      | `0x4000_0000` | 4K    | CTRL/STATUS/CFG_A/CFG_B (only 0x00–0x0C used) |
| `axi_bram_ctrl_ifm`    | `0x4001_0000` | 64K   | IFM tile staging                              |
| `axi_bram_ctrl_weight` | `0x4002_0000` | 128K  | WEIGHT tile staging                           |
| `axi_bram_ctrl_ofm`    | `0x4004_0000` | 256K  | OFM tile results                              |

### 2h. Validate and build

- `Validate Design` (F6) — fix any unconnected-port or width-mismatch errors.
- `Generate Block Design`, then create the HDL wrapper
  (`Create HDL Wrapper`, let Vivado manage it).
- Run **Synthesis -> Implementation -> Generate Bitstream**.
- Export hardware (`.xsa`, include bitstream) for Vitis.
- For PYNQ, copy the bitstream and the block design's hardware handoff,
  `<project>.gen/sources_1/bd/npu_bd/hw_handoff/npu_bd.hwh`, to one directory on the board as
  `npu.bit` and `npu.hwh`; PYNQ pairs the two by name. `tools/build.tcl` writes both to `build/`.

## 3. PYNQ-side access

With `npu.bit` loaded as a PYNQ `Overlay` (which reads `npu.hwh` from the same directory), each
AXI-mapped region becomes accessible as `pynq.MMIO`:

```python
from pynq import Overlay, MMIO

ol = Overlay("npu.bit")

CSR    = MMIO(0x4000_0000, 0x1000)   # npu_top CSR
IFM    = MMIO(0x4001_0000, 0x10000)
WEIGHT = MMIO(0x4002_0000, 0x20000)
OFM    = MMIO(0x4004_0000, 0x40000)

# stage one tile's IFM bytes / weight bytes via IFM.write(offset, value), ...
# then run_tile(CSR, ...) as in docs/register_map.md
```

Each `MMIO.write(offset, word)` / `.read(offset)` is a 32-bit AXI transfer. The
IFM/WEIGHT BRAMs hold four int8 values per 32-bit word (see step 2f) — the PS
packs them byte 0 in bits `[7:0]`. Since x86/ARM are little-endian, an `int8`
numpy array can be reinterpreted and written directly:

```python
ifm_words = ifm_bytes.view(np.uint32)      # ifm_bytes: int8 array, len % 4 == 0
for i, w in enumerate(ifm_words):
    IFM.write(i * 4, int(w))
```

`npu_top` reads this back with `byte_sel = addr[1:0]` selecting
`dout[8*byte_sel +: 8]`, i.e. the same little-endian byte order.

## 4. Verifying the design

- RTL checks: `python tools/run_sims.py` regenerates the test vectors with
  `tools/gen_tb_vectors.py` and simulates `rtl/tb/tb_conv_engine.sv` (the
  datapath alone) and `rtl/tb/tb_npu_top.sv` (the packaged IP, driven through
  its AXI4-Lite CSRs, with port-B models of the BMGs, as the PS drives it) in
  Vivado's simulator or Verilator. They print `PASS: all 32 OFM words match
  golden model` and `PASS: all 5742 OFM words of 5 tiles match golden model
  through the AXI4-Lite CSRs`.
- Block design check (on the board): after generating the bitstream, write a
  short PYNQ script that stages a known IFM/weight tile via `MMIO`, pulses
  `CTRL.start`, polls `STATUS.done`, and compares the OFM region against
  `golden_model/conv2d.py`'s `conv2d_6for` for the same tile — this is the same
  comparison `tb_npu_top.sv` does in simulation, but through the real AXI BRAM
  controllers and block RAM.
