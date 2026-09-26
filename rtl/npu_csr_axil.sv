`timescale 1ns / 1ps

// AXI4-Lite slave exposing the Configurable Controller's CSRs (see
// docs/register_map.md):
//
//   0x00 CTRL    [0]    start   (W: pulse -- write 1 then 0)
//   0x04 STATUS  [0]    done    (RO, latched from conv_engine's done pulse,
//                                 cleared when start_pulse fires)
//   0x08 CFG_A   [7:0]  input_ch
//                [15:8] output_ch (oc_range)
//                [23:16] kernel_h
//                [31:24] kernel_w
//   0x0C CFG_B   [8:0]  tile_h
//                [17:9] tile_w
//                [20:18] stride
//
// Decoded config fields and start_pulse/done are exported as plain signals
// for conv_engine.sv. Address decoding uses bits [3:2] of the AXI address
// (4-byte register stride, standard AXI4-Lite peripheral layout).

module npu_csr_axil #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4
) (
    // Global
    input  logic                              s_axi_aclk,
    input  logic                              s_axi_aresetn,

    // AXI4-Lite write address channel
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [2:0]                        s_axi_awprot,
    input  logic                              s_axi_awvalid,
    output logic                              s_axi_awready,

    // AXI4-Lite write data channel
    input  logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                              s_axi_wvalid,
    output logic                              s_axi_wready,

    // AXI4-Lite write response channel
    output logic [1:0]                        s_axi_bresp,
    output logic                              s_axi_bvalid,
    input  logic                              s_axi_bready,

    // AXI4-Lite read address channel
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [2:0]                        s_axi_arprot,
    input  logic                              s_axi_arvalid,
    output logic                              s_axi_arready,

    // AXI4-Lite read data channel
    output logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output logic [1:0]                        s_axi_rresp,
    output logic                              s_axi_rvalid,
    input  logic                              s_axi_rready,

    // Decoded CSR outputs -> conv_engine
    output logic        start_pulse,
    output logic [7:0]  input_ch,
    output logic [7:0]  output_ch,
    output logic [7:0]  kernel_h,
    output logic [7:0]  kernel_w,
    output logic [8:0]  tile_h,
    output logic [8:0]  tile_w,
    output logic [2:0]  stride,

    // conv_engine -> STATUS.done
    input  logic        done
);

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    // ------------------------------------------------------------
    // AXI4-Lite write channel
    // ------------------------------------------------------------
    logic                          axi_awready;
    logic                          axi_wready;
    logic                          axi_bvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = AXI_RESP_OKAY;
    assign s_axi_bvalid  = axi_bvalid;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_awaddr  <= '0;
        end else begin
            // accept a write address+data pair when both are valid and
            // we are not still waiting on a previous BVALID handshake
            if (!axi_awready && s_axi_awvalid && s_axi_wvalid && !axi_bvalid) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
                axi_awaddr  <= s_axi_awaddr;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end

            if (axi_awready && axi_wready) begin
                axi_bvalid <= 1'b1;
            end else if (axi_bvalid && s_axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    wire reg_write = axi_awready && axi_wready && s_axi_awvalid && s_axi_wvalid;
    wire [1:0] waddr_idx = axi_awaddr[3:2];

    // ------------------------------------------------------------
    // CSR storage
    // ------------------------------------------------------------
    logic [31:0] reg_ctrl;   // CTRL   (0x00) -- bit0 readback only, not stateful
    logic [31:0] reg_cfg_a;  // CFG_A  (0x08)
    logic [31:0] reg_cfg_b;  // CFG_B  (0x0C)
    logic        done_latched; // STATUS.done (0x04)

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            reg_ctrl  <= '0;
            reg_cfg_a <= '0;
            reg_cfg_b <= '0;
        end else if (reg_write) begin
            unique case (waddr_idx)
                2'd0: if (s_axi_wstrb[0]) reg_ctrl  <= {reg_ctrl[31:1],  s_axi_wdata[0]};
                2'd2: for (int b = 0; b < 4; b++)
                          if (s_axi_wstrb[b]) reg_cfg_a[8*b +: 8] <= s_axi_wdata[8*b +: 8];
                2'd3: for (int b = 0; b < 4; b++)
                          if (s_axi_wstrb[b]) reg_cfg_b[8*b +: 8] <= s_axi_wdata[8*b +: 8];
                default: ; // STATUS (0x04) is read-only
            endcase
        end
    end

    // start_pulse: one-cycle pulse the cycle the write to CTRL with bit0=1 lands
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= reg_write && (waddr_idx == 2'd0) && s_axi_wstrb[0] && s_axi_wdata[0];
        end
    end

    // STATUS.done: set on conv_engine's done pulse, cleared when a new
    // tile is started
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            done_latched <= 1'b0;
        end else if (start_pulse) begin
            done_latched <= 1'b0;
        end else if (done) begin
            done_latched <= 1'b1;
        end
    end

    // ------------------------------------------------------------
    // Decoded CSR outputs
    // ------------------------------------------------------------
    assign input_ch  = reg_cfg_a[7:0];
    assign output_ch = reg_cfg_a[15:8];
    assign kernel_h  = reg_cfg_a[23:16];
    assign kernel_w  = reg_cfg_a[31:24];
    assign tile_h    = reg_cfg_b[8:0];
    assign tile_w    = reg_cfg_b[17:9];
    assign stride    = reg_cfg_b[20:18];

    // ------------------------------------------------------------
    // AXI4-Lite read channel
    // ------------------------------------------------------------
    logic                          axi_arready;
    logic                          axi_rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    logic [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;

    assign s_axi_arready = axi_arready;
    assign s_axi_rresp   = AXI_RESP_OKAY;
    assign s_axi_rvalid  = axi_rvalid;
    assign s_axi_rdata   = axi_rdata;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_araddr  <= '0;
            axi_rdata   <= '0;
        end else begin
            if (!axi_arready && s_axi_arvalid && !axi_rvalid) begin
                axi_arready <= 1'b1;
                axi_araddr  <= s_axi_araddr;
            end else begin
                axi_arready <= 1'b0;
            end

            if (axi_arready && s_axi_arvalid && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                unique case (s_axi_araddr[3:2])
                    2'd0: axi_rdata <= reg_ctrl;
                    2'd1: axi_rdata <= {31'b0, done_latched};
                    2'd2: axi_rdata <= reg_cfg_a;
                    2'd3: axi_rdata <= reg_cfg_b;
                    default: axi_rdata <= '0;
                endcase
            end else if (axi_rvalid && s_axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
