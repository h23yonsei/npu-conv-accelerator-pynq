`timescale 1ns / 1ps

// Top-level testbench for the packaged npu_top IP, driven the way the PS driver in
// docs/register_map.md drives it. For each tile in tb_top_cases.svh (generated with its vectors by
// tools/gen_tb_vectors.py) it:
//
//   - fills the IFM and WEIGHT memories with the tile's int8 values, four per 32-bit word in
//     little-endian order, as the PS writes them through the AXI BRAM controllers;
//   - writes CFG_A and CFG_B over AXI4-Lite and reads them back;
//   - writes CTRL = 1 then CTRL = 0, and polls STATUS until done is set;
//   - compares every OFM word with the golden model, and checks that the 16 words after the tile
//     were not written.
//
// It also checks that STATUS.done reads 0 before the first tile and is cleared by each new start.
// The three BRAM port Bs are modeled on the Block Memory Generator cores of the block design, which
// IP Integrator configures for the AXI BRAM Controllers on port A: 32-bit words, one cycle of read
// latency, and on port B a 32-bit byte address, of which the memory ignores the two low bits, and
// one write enable per byte. Stimulus changes 1 ns after the rising edge.
//
// Run with `python tools/run_sims.py`, from a directory holding vectors/ and with rtl/tb on the
// include path.

module tb_npu_top;

    `include "tb_top_cases.svh"

    localparam int IFM_ADDR_W = 15;
    localparam int WGT_ADDR_W = 17;
    localparam int OFM_ADDR_W = 16;

    localparam logic [3:0] CTRL = 4'h0, STATUS = 4'h4, CFG_A = 4'h8, CFG_B = 4'hC;
    localparam logic [31:0] UNWRITTEN = 32'hDEAD_BEEF;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic resetn = 1'b0;

    // AXI4-Lite master signals, driven by the tasks below
    logic [3:0]  awaddr  = '0;
    logic        awvalid = 1'b0;
    logic        awready;
    logic [31:0] wdata   = '0;
    logic [3:0]  wstrb   = '0;
    logic        wvalid  = 1'b0;
    logic        wready;
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready  = 1'b0;
    logic [3:0]  araddr  = '0;
    logic        arvalid = 1'b0;
    logic        arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready  = 1'b0;

    // BRAM port B interfaces
    logic                  ifm_bram_clk, ifm_bram_en;
    logic [3:0]            ifm_bram_we;
    logic [31:0]           ifm_bram_addr;
    logic [31:0]           ifm_bram_din;
    logic [31:0]           ifm_bram_dout = '0;

    logic                  wgt_bram_clk, wgt_bram_en;
    logic [3:0]            wgt_bram_we;
    logic [31:0]           wgt_bram_addr;
    logic [31:0]           wgt_bram_din;
    logic [31:0]           wgt_bram_dout = '0;

    logic                  ofm_bram_clk, ofm_bram_en;
    logic [3:0]            ofm_bram_we;
    logic [31:0]           ofm_bram_addr;
    logic [31:0]           ofm_bram_din;
    logic [31:0]           ofm_bram_dout = '0;

    npu_top #(
        .IFM_ADDR_W(IFM_ADDR_W),
        .WGT_ADDR_W(WGT_ADDR_W),
        .OFM_ADDR_W(OFM_ADDR_W)
    ) dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (resetn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (3'b000),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (3'b000),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready),

        .ifm_bram_clk  (ifm_bram_clk),
        .ifm_bram_en   (ifm_bram_en),
        .ifm_bram_we   (ifm_bram_we),
        .ifm_bram_addr (ifm_bram_addr),
        .ifm_bram_din  (ifm_bram_din),
        .ifm_bram_dout (ifm_bram_dout),

        .wgt_bram_clk  (wgt_bram_clk),
        .wgt_bram_en   (wgt_bram_en),
        .wgt_bram_we   (wgt_bram_we),
        .wgt_bram_addr (wgt_bram_addr),
        .wgt_bram_din  (wgt_bram_din),
        .wgt_bram_dout (wgt_bram_dout),

        .ofm_bram_clk  (ofm_bram_clk),
        .ofm_bram_en   (ofm_bram_en),
        .ofm_bram_we   (ofm_bram_we),
        .ofm_bram_addr (ofm_bram_addr),
        .ofm_bram_din  (ofm_bram_din),
        .ofm_bram_dout (ofm_bram_dout)
    );

    // ------------------------------------------------------------
    // BRAMs: 32-bit words, one cycle of read latency on port B, which takes a byte address (the
    // low two bits ignored) and a write enable per byte, as the Block Memory Generator does in the
    // block design. Port B addresses must stay inside the region npu_top uses, and the IFM and
    // WEIGHT memories must never be written from port B.
    // ------------------------------------------------------------
    logic [31:0] ifm_mem [0:(1 << (IFM_ADDR_W - 2)) - 1];
    logic [31:0] wgt_mem [0:(1 << (WGT_ADDR_W - 2)) - 1];
    logic [31:0] ofm_mem [0:(1 << OFM_ADDR_W) - 1];

    always @(posedge clk) begin
        if (ifm_bram_en) ifm_bram_dout <= ifm_mem[ifm_bram_addr[IFM_ADDR_W-1:2]];
        if (wgt_bram_en) wgt_bram_dout <= wgt_mem[wgt_bram_addr[WGT_ADDR_W-1:2]];
        if (ofm_bram_en)
            for (int b = 0; b < 4; b++)
                if (ofm_bram_we[b])
                    ofm_mem[ofm_bram_addr[OFM_ADDR_W+1:2]][8*b +: 8] <= ofm_bram_din[8*b +: 8];
        if (ifm_bram_en && (ifm_bram_we != '0 || ifm_bram_addr[31:IFM_ADDR_W] != '0))
            fail($sformatf("IFM port B: we = %b, address %08h", ifm_bram_we, ifm_bram_addr));
        if (wgt_bram_en && (wgt_bram_we != '0 || wgt_bram_addr[31:WGT_ADDR_W] != '0))
            fail($sformatf("WEIGHT port B: we = %b, address %08h", wgt_bram_we, wgt_bram_addr));
        if (ofm_bram_en && ofm_bram_we != '0 && ofm_bram_addr[31:OFM_ADDR_W+2] != '0)
            fail($sformatf("OFM port B: write to address %08h", ofm_bram_addr));
    end

    // ------------------------------------------------------------
    // AXI4-Lite master. Each task is called just after a rising edge and returns just after one.
    // Handshake signals are sampled at the rising edge, when they hold the values the slave sees.
    // ------------------------------------------------------------
    task automatic axi_write(input logic [3:0] addr, input logic [31:0] data);
        #1;
        awaddr = addr; awvalid = 1'b1;
        wdata  = data; wstrb   = 4'hF; wvalid = 1'b1;
        @(posedge clk);
        while (!(awready && wready)) @(posedge clk);
        #1;
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        #1 bready = 1'b0;
        @(posedge clk);
    endtask

    task automatic axi_read(input logic [3:0] addr, output logic [31:0] data);
        #1;
        araddr = addr; arvalid = 1'b1; rready = 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        #1 arvalid = 1'b0;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        data = rdata;
        #1 rready = 1'b0;
        @(posedge clk);
    endtask

    // ------------------------------------------------------------
    // Test
    // ------------------------------------------------------------
    logic [7:0]  ifm_bytes [0:(1 << IFM_ADDR_W) - 1];
    logic [7:0]  wgt_bytes [0:(1 << WGT_ADDR_W) - 1];
    logic [31:0] expected  [0:(1 << OFM_ADDR_W) - 1];

    logic [31:0] cfg_a, cfg_b, value;
    int errors  = 0;
    int checked = 0;
    int polls;
    string file;

    task automatic fail(input string what);
        errors++;
        if (errors <= 10) $display("MISMATCH %s", what);
    endtask

    initial begin
        repeat (4) @(posedge clk);
        #1 resetn = 1'b1;
        @(posedge clk);

        axi_read(STATUS, value);
        if (value !== 32'd0) fail($sformatf("STATUS after reset: %08h, expected 0", value));

        for (int n = 0; n < TOP_CASES; n++) begin
            // the PS writes the IFM window and the weights, packed four bytes per word
            $sformat(file, "vectors/top_case%0d_ifm.mem", n);
            $readmemh(file, ifm_bytes, 0, TOP_IFM_BYTES[n] - 1);
            $sformat(file, "vectors/top_case%0d_weight.mem", n);
            $readmemh(file, wgt_bytes, 0, TOP_WGT_BYTES[n] - 1);
            $sformat(file, "vectors/top_case%0d_ofm.mem", n);
            $readmemh(file, expected, 0, TOP_OFM_WORDS[n] - 1);

            for (int b = 0; b < TOP_IFM_BYTES[n]; b++) ifm_mem[b / 4][8 * (b % 4) +: 8] = ifm_bytes[b];
            for (int b = 0; b < TOP_WGT_BYTES[n]; b++) wgt_mem[b / 4][8 * (b % 4) +: 8] = wgt_bytes[b];
            for (int w = 0; w < TOP_OFM_WORDS[n] + 16; w++) ofm_mem[w] = UNWRITTEN;

            // configure, and read the configuration back
            cfg_a = TOP_INPUT_CH[n] | (TOP_OUTPUT_CH[n] << 8) | (TOP_KERNEL_H[n] << 16) | (TOP_KERNEL_W[n] << 24);
            cfg_b = TOP_TILE_H[n] | (TOP_TILE_W[n] << 9) | (TOP_STRIDE[n] << 18);
            axi_write(CFG_A, cfg_a);
            axi_write(CFG_B, cfg_b);
            axi_read(CFG_A, value);
            if (value !== cfg_a) fail($sformatf("case %0d: CFG_A reads %08h, wrote %08h", n, value, cfg_a));
            axi_read(CFG_B, value);
            if (value !== cfg_b) fail($sformatf("case %0d: CFG_B reads %08h, wrote %08h", n, value, cfg_b));

            // start, then poll STATUS.done; a new start must clear the previous tile's done
            axi_write(CTRL, 32'd1);
            axi_write(CTRL, 32'd0);
            axi_read(STATUS, value);
            polls = 0;
            if (value[0] !== 1'b0)
                fail($sformatf("case %0d: STATUS.done set right after start", n));
            while (value[0] !== 1'b1 && polls < 1_000_000) begin
                axi_read(STATUS, value);
                polls++;
            end
            if (value[0] !== 1'b1) begin
                fail($sformatf("case %0d: STATUS.done never set", n));
                break;
            end

            // the tile, and nothing after it
            for (int w = 0; w < TOP_OFM_WORDS[n]; w++) begin
                checked++;
                if (ofm_mem[w] !== expected[w])
                    fail($sformatf("case %0d: OFM[%0d] = %08h, expected %08h", n, w, ofm_mem[w], expected[w]));
            end
            for (int w = TOP_OFM_WORDS[n]; w < TOP_OFM_WORDS[n] + 16; w++)
                if (ofm_mem[w] !== UNWRITTEN)
                    fail($sformatf("case %0d: OFM[%0d] written past the end of the tile", n, w));

            $display("case %0d: %0d OFM words checked, done after %0d STATUS polls", n, TOP_OFM_WORDS[n], polls);
        end

        if (errors == 0)
            $display("PASS: all %0d OFM words of %0d tiles match golden model through the AXI4-Lite CSRs",
                     checked, TOP_CASES);
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
