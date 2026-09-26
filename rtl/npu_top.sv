`timescale 1ns / 1ps

// Top-level module to package as the custom NPU IP in Vivado IP Integrator.
//
//   - S_AXI: AXI4-Lite slave (-> npu_csr_axil) for the CTRL/STATUS/CFG_A/CFG_B
//     CSRs (docs/register_map.md). Connect to ZYNQ7 PS M_AXI_GP0 via an
//     AXI Interconnect / SmartConnect.
//   - ifm_bram_*, wgt_bram_*, ofm_bram_*: native (non-AXI) BRAM port-B
//     interfaces (Block Memory Generator "True Dual Port", port B), driven
//     by conv_engine. Port A of each BRAM connects to its own AXI BRAM
//     Controller for PS access (see docs/block_design.md).
//
// Port naming follows Vivado's convention for BRAM_PORT bus interfaces
// (<name>_addr/_clk/_en/_we/_din/_dout) so the IP packager can group them
// into BRAM_PORT interfaces during "Package IP".

module npu_top #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4,

    parameter integer IFM_ADDR_W = 15,  // IFM BRAM depth  = 2^15 = 32768 x 8b  (32KB)
    parameter integer WGT_ADDR_W = 17,  // WEIGHT BRAM depth = 2^17 = 131072 x 8b (128KB)
    parameter integer OFM_ADDR_W = 16   // OFM BRAM depth = 2^16 = 65536 x 32b (256KB)
) (
    // ------------------------------------------------------------
    // AXI4-Lite slave (CSR)
    // ------------------------------------------------------------
    input  logic                              s_axi_aclk,
    input  logic                              s_axi_aresetn,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [2:0]                        s_axi_awprot,
    input  logic                              s_axi_awvalid,
    output logic                              s_axi_awready,

    input  logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                              s_axi_wvalid,
    output logic                              s_axi_wready,

    output logic [1:0]                        s_axi_bresp,
    output logic                              s_axi_bvalid,
    input  logic                              s_axi_bready,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [2:0]                        s_axi_arprot,
    input  logic                              s_axi_arvalid,
    output logic                              s_axi_arready,

    output logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output logic [1:0]                        s_axi_rresp,
    output logic                              s_axi_rvalid,
    input  logic                              s_axi_rready,

    // ------------------------------------------------------------
    // IFM BRAM, native port B (read-only from conv_engine)
    //   32 bits wide: BMG True Dual Port requires Port B width >= Port A
    //   width, so this BRAM is symmetric 32-bit on both ports. With an AXI
    //   BRAM Controller on port A, IP Integrator puts the BMG in BRAM
    //   Controller mode, where port B too takes a 32-bit byte address (the
    //   BMG ignores its two low bits) and one write enable per byte. The
    //   byte within the word is selected internally (see ifm_byte_sel_r).
    // ------------------------------------------------------------
    output logic                   ifm_bram_clk,
    output logic                   ifm_bram_en,
    output logic [3:0]             ifm_bram_we,
    output logic [31:0]            ifm_bram_addr,
    output logic [31:0]            ifm_bram_din,
    input  logic [31:0]            ifm_bram_dout,

    // ------------------------------------------------------------
    // WEIGHT BRAM, native port B (read-only from conv_engine)
    //   32 bits wide, byte address, byte write enables -- see IFM above.
    // ------------------------------------------------------------
    output logic                   wgt_bram_clk,
    output logic                   wgt_bram_en,
    output logic [3:0]             wgt_bram_we,
    output logic [31:0]            wgt_bram_addr,
    output logic [31:0]            wgt_bram_din,
    input  logic [31:0]            wgt_bram_dout,

    // ------------------------------------------------------------
    // OFM BRAM, native port B (write-only from conv_engine)
    //   32 bits wide, byte address, byte write enables -- see IFM above.
    // ------------------------------------------------------------
    output logic                   ofm_bram_clk,
    output logic                   ofm_bram_en,
    output logic [3:0]             ofm_bram_we,
    output logic [31:0]            ofm_bram_addr,
    output logic [31:0]            ofm_bram_din,
    input  logic [31:0]            ofm_bram_dout
);

    logic        start_pulse;
    logic [7:0]  input_ch, output_ch, kernel_h, kernel_w;
    logic [8:0]  tile_h, tile_w;
    logic [2:0]  stride;
    logic        done;

    npu_csr_axil #(
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) u_csr (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),

        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),

        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),

        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),

        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),

        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        .start_pulse (start_pulse),
        .input_ch    (input_ch),
        .output_ch   (output_ch),
        .kernel_h    (kernel_h),
        .kernel_w    (kernel_w),
        .tile_h      (tile_h),
        .tile_w      (tile_w),
        .stride      (stride),
        .done        (done)
    );

    // conv_engine BRAM read-data buses, driven from the *_bram_dout inputs
    logic [7:0]  ifm_rdata, wgt_rdata;
    logic [31:0] ofm_wdata_int;
    logic        ofm_we_int;
    logic [IFM_ADDR_W-1:0] ifm_addr_int;
    logic [WGT_ADDR_W-1:0] wgt_addr_int;
    logic [OFM_ADDR_W-1:0] ofm_addr_int;

    // IFM/WEIGHT BRAMs are 32-bit on both ports (see port comments above);
    // conv_engine still addresses them as individual bytes, so register the
    // low 2 address bits for one cycle (matching the BRAM's own 1-cycle
    // read latency) and use them to select the byte out of *_bram_dout.
    logic [1:0] ifm_byte_sel_r, wgt_byte_sel_r;

    always_ff @(posedge s_axi_aclk) begin
        ifm_byte_sel_r <= ifm_addr_int[1:0];
        wgt_byte_sel_r <= wgt_addr_int[1:0];
    end

    assign ifm_rdata = ifm_bram_dout[8*ifm_byte_sel_r +: 8];
    assign wgt_rdata = wgt_bram_dout[8*wgt_byte_sel_r +: 8];

    conv_engine #(
        .IFM_ADDR_W(IFM_ADDR_W),
        .WGT_ADDR_W(WGT_ADDR_W),
        .OFM_ADDR_W(OFM_ADDR_W)
    ) u_conv (
        .clk        (s_axi_aclk),
        .rst_n      (s_axi_aresetn),

        .input_ch   (input_ch),
        .output_ch  (output_ch),
        .kernel_h   (kernel_h),
        .kernel_w   (kernel_w),
        .tile_h     (tile_h),
        .tile_w     (tile_w),
        .stride     (stride),

        .start      (start_pulse),
        .done       (done),
        .busy       (),

        .ifm_addr   (ifm_addr_int),
        .ifm_rdata  (ifm_rdata),

        .wgt_addr   (wgt_addr_int),
        .wgt_rdata  (wgt_rdata),

        .ofm_addr   (ofm_addr_int),
        .ofm_wdata  (ofm_wdata_int),
        .ofm_we     (ofm_we_int)
    );

    // ------------------------------------------------------------
    // IFM BRAM port B: always reading, never writing
    // ------------------------------------------------------------
    assign ifm_bram_clk  = s_axi_aclk;
    assign ifm_bram_en   = 1'b1;
    assign ifm_bram_we   = 4'b0000;
    assign ifm_bram_addr = 32'({ifm_addr_int[IFM_ADDR_W-1:2], 2'b00});
    assign ifm_bram_din  = 32'b0;

    // ------------------------------------------------------------
    // WEIGHT BRAM port B: always reading, never writing
    // ------------------------------------------------------------
    assign wgt_bram_clk  = s_axi_aclk;
    assign wgt_bram_en   = 1'b1;
    assign wgt_bram_we   = 4'b0000;
    assign wgt_bram_addr = 32'({wgt_addr_int[WGT_ADDR_W-1:2], 2'b00});
    assign wgt_bram_din  = 32'b0;

    // ------------------------------------------------------------
    // OFM BRAM port B: write-only, one int32 result per word
    // ------------------------------------------------------------
    assign ofm_bram_clk  = s_axi_aclk;
    assign ofm_bram_en   = 1'b1;
    assign ofm_bram_we   = {4{ofm_we_int}};
    assign ofm_bram_addr = 32'({ofm_addr_int, 2'b00});
    assign ofm_bram_din  = ofm_wdata_int;

endmodule
