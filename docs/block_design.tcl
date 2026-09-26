# block_design.tcl
#
# Scaffold for the block design described in docs/block_design.md. The
# committed project in vivado/ is the reference design; this script has not
# been run against a fresh project, so treat it as a starting point: source
# it, then fix up whatever `validate_bd_design` complains about (interface
# names on npu_top in particular depend on exactly how the IP packager
# grouped its ports).
#
# Prerequisites (do these first, in the Vivado GUI):
#   1. Open/create a project targeting your board (PYNQ-Z2).
#   2. Package rtl/ as npu_top_v1_0 (see docs/block_design.md section 1)
#      and add the IP repo under Project Settings -> IP -> Repository,
#      then click "Refresh All".
#   3. If npu_top_0 / a BMG were already created from an earlier attempt
#      (e.g. npu_top.sv's BRAM port widths changed since packaging), re-open
#      the IP packager, click "Merge changes from File Groups Wizard" and
#      re-package, then delete the partial npu_bd before re-sourcing this
#      script so section 3 runs cleanly for all three BMGs.
#
# Usage (Tcl console):
#   source docs/block_design.tcl

create_bd_design "npu_bd"

# ------------------------------------------------------------
# 1. ZYNQ7 Processing System
# ------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    [get_bd_cells processing_system7_0]

# FCLK_CLK0 at 50 MHz, as in the committed design: the longest path (the OFM BRAM controller's
# address fanning out to the OFM's 64 block RAMs, 15.3 ns) does not fit the 100 MHz default.
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} \
                         CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50}] \
    [get_bd_cells processing_system7_0]

# ------------------------------------------------------------
# 2. npu_top (packaged custom IP)
#    Register the rtl/ directory (containing component.xml) as an IP repo
#    for this project, then refresh the catalog so the VLNV below resolves.
#    VLNV is xilinx.com:user:npu_top:1.0 per rtl/component.xml's
#    <spirit:vendor>/<spirit:library>/<spirit:name>/<spirit:version>.
# ------------------------------------------------------------
# Resolved relative to this script: docs/block_design.tcl -> ../rtl
set repo_root [file normalize [file join [file dirname [info script]] ..]]
set_property ip_repo_paths [file join $repo_root rtl] [current_project]
update_ip_catalog -rebuild

create_bd_cell -type ip -vlnv xilinx.com:user:npu_top:1.0 npu_top_0

# ------------------------------------------------------------
# 3. Block Memory Generators (True Dual Port)
#    All three are symmetric 32-bit on both ports (Port A: PS side via AXI
#    BRAM Ctrl; Port B: HW side, npu_top/conv_engine). Depths per
#    docs/block_design.md section 2c. Once section 4 connects an AXI BRAM
#    Controller to port A, IP Integrator puts each BMG in BRAM Controller
#    mode: the depth follows the address range (section 7), and both ports
#    take 32-bit byte addresses and one write enable per byte.
#
#    NOTE: BMG True Dual Port RAM requires Port B width >= Port A width (in
#    1x/2x/4x multiples) -- it does NOT support a narrower Port B (e.g. 8-bit
#    Port B with 32-bit Port A fails with "Valid values are - 32" regardless
#    of property ordering). conv_engine's 8-bit IFM/WEIGHT accesses are
#    adapted to these 32-bit ports inside npu_top.sv (byte-select mux).
# ------------------------------------------------------------
foreach {name depth} {
    bram_ifm     16384
    bram_weight  32768
    bram_ofm    65536
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 $name
    set_property -dict [list \
        CONFIG.Memory_Type {True_Dual_Port_RAM} \
        CONFIG.Write_Width_A {32} \
        CONFIG.Read_Width_A {32} \
        CONFIG.Write_Width_B {32} \
        CONFIG.Read_Width_B {32} \
        CONFIG.Write_Depth_A $depth \
        CONFIG.Enable_B {Use_ENB_Pin} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    ] [get_bd_cells $name]
}

# ------------------------------------------------------------
# 4. AXI BRAM Controllers (PS-facing, Port A of each BMG)
# ------------------------------------------------------------
foreach {ctrl bram} {
    axi_bram_ctrl_ifm    bram_ifm
    axi_bram_ctrl_weight bram_weight
    axi_bram_ctrl_ofm    bram_ofm
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 $ctrl
    set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.ECC_TYPE {0}] [get_bd_cells $ctrl]
    connect_bd_intf_net [get_bd_intf_pins $ctrl/BRAM_PORTA] [get_bd_intf_pins $bram/BRAM_PORTA]
}

# ------------------------------------------------------------
# 5. Native BRAM Port B's -> npu_top (flat pin connections)
#    BMG Port B pins: ADDRB/ENB/WEB/DINB/DOUTB (flat, not a BRAM_PORTB
#    bus interface). Widths match directly: ADDRB = 32-bit byte address
#    (the BMG ignores the two low bits), DINB/DOUTB = 32-bit, WEB = 4-bit
#    (one per byte), as npu_top (core revision 3) drives them.
#
#    CLKB: TDP mode has independent clocks by default; -quiet avoids a
#    crash if this BMG is in common-clock mode (no CLKB pin -> fall back
#    to shared CLKA). npu_top_0's *_bram_clk ports are packaged as clock
#    bus interfaces (master); get_bd_pins should still return the physical
#    pin in Vivado 2022.1, but if not (-quiet -> empty list), CLKB is
#    driven directly from FCLK_CLK0 instead.
# ------------------------------------------------------------
foreach {prefix bram} {
    ifm bram_ifm
    wgt bram_weight
    ofm bram_ofm
} {
    connect_bd_net [get_bd_pins npu_top_0/${prefix}_bram_addr] [get_bd_pins $bram/ADDRB]
    connect_bd_net [get_bd_pins npu_top_0/${prefix}_bram_en]   [get_bd_pins $bram/ENB]
    connect_bd_net [get_bd_pins npu_top_0/${prefix}_bram_we]   [get_bd_pins $bram/WEB]
    connect_bd_net [get_bd_pins npu_top_0/${prefix}_bram_din]  [get_bd_pins $bram/DINB]
    connect_bd_net [get_bd_pins npu_top_0/${prefix}_bram_dout] [get_bd_pins $bram/DOUTB]

    # CLKB: only connect if the pin exists. If absent (common-clock TDP mode),
    # CLKA is already driven by the BRAM_PORTA interface from section 4 --
    # adding a second source would be a multi-driver error, so skip it.
    set clkb_pin [get_bd_pins ${bram}/CLKB -quiet]
    if {[llength $clkb_pin] > 0} {
        set npu_clk [get_bd_pins npu_top_0/${prefix}_bram_clk -quiet]
        if {[llength $npu_clk] > 0} {
            connect_bd_net $npu_clk $clkb_pin
        } else {
            connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] $clkb_pin
        }
    }
}

# ------------------------------------------------------------
# 6. AXI interconnect, clocks, and resets
#    Explicit wiring (more reliable than apply_bd_automation in a loop).
# ------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     \
               [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
               [get_bd_pins rst_ps7_0_100M/ext_reset_in]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4}] [get_bd_cells axi_smc]
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                    [get_bd_intf_pins axi_bram_ctrl_ifm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] \
                    [get_bd_intf_pins axi_bram_ctrl_weight/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] \
                    [get_bd_intf_pins axi_bram_ctrl_ofm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] \
                    [get_bd_intf_pins npu_top_0/S_AXI]

set fclk [get_bd_pins processing_system7_0/FCLK_CLK0]
foreach clk_pin {
    processing_system7_0/M_AXI_GP0_ACLK
    axi_smc/aclk
    axi_bram_ctrl_ifm/s_axi_aclk
    axi_bram_ctrl_weight/s_axi_aclk
    axi_bram_ctrl_ofm/s_axi_aclk
    npu_top_0/s_axi_aclk
} {
    connect_bd_net $fclk [get_bd_pins $clk_pin]
}

set arstn [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
foreach rst_pin {
    axi_smc/aresetn
    axi_bram_ctrl_ifm/s_axi_aresetn
    axi_bram_ctrl_weight/s_axi_aresetn
    axi_bram_ctrl_ofm/s_axi_aresetn
    npu_top_0/s_axi_aresetn
} {
    connect_bd_net $arstn [get_bd_pins $rst_pin]
}

# ------------------------------------------------------------
# 7. Address map — auto-assign then pin to the expected base addresses
#    from docs/block_design.md section 2g. If get_bd_addr_segs returns
#    nothing (segment named differently), check the Address Editor and
#    adjust the path (e.g. Reg -> reg0, Mem0 -> mem0).
# ------------------------------------------------------------
assign_bd_address

# npu_top_0 auto-assigns to 0x40000000 [4K] -- correct, leave as-is.
# Re-assign BRAM controllers to the expected addresses.
# (set_property offset/range doesn't work on addr_segs; use assign_bd_address.)
assign_bd_address -offset 0x40010000 -range 64K  [get_bd_addr_segs {axi_bram_ctrl_ifm/S_AXI/Mem0}]
assign_bd_address -offset 0x40020000 -range 128K [get_bd_addr_segs {axi_bram_ctrl_weight/S_AXI/Mem0}]
assign_bd_address -offset 0x40040000 -range 256K [get_bd_addr_segs {axi_bram_ctrl_ofm/S_AXI/Mem0}]

# ------------------------------------------------------------
# 8. Validate and save
# ------------------------------------------------------------
regenerate_bd_layout
validate_bd_design
save_bd_design
