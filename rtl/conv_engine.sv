`timescale 1ns / 1ps

// Single-MAC datapath that computes ONE output tile of conv2d_9for's inner
// loop (see docs/register_map.md "Hardware contract"):
//
//   for toc in range(output_ch):       # oc_range
//     for toh in range(tile_h):
//       for tow in range(tile_w):
//         temp = 0
//         for ic in range(input_ch):
//           for kh in range(kernel_h):
//             for kw in range(kernel_w):
//               temp += ifm[ic, toh*stride+kh, tow*stride+kw] * weight[toc, ic, kh, kw]
//         ofm[toc, toh, tow] = temp
//
// IFM/WEIGHT/OFM are native-interface BRAM port B's:
//   IFM:    [ic][h][w]              int8,  row-major, h = (tile_h-1)*stride+kernel_h wide
//   WEIGHT: [toc][ic][kh][kw]       int8,  row-major
//   OFM:    [toc][toh][tow]         int32, row-major
//
// BRAM timing assumption (matches Block Memory Generator "Native" interface
// WITHOUT the optional output register): 1-cycle synchronous read latency --
// data presented on *_rdata one cycle after *_addr is registered.
//
// config inputs (input_ch, output_ch, kernel_h, kernel_w, tile_h, tile_w,
// stride) are sampled when `start` is asserted and held for the duration of
// the tile. The caller must guarantee input_ch/output_ch/kernel_h/kernel_w
// >= 1 and tile_h/tile_w >= 1 (a tile with zero elements is not a valid
// configuration).

module conv_engine #(
    parameter integer IFM_ADDR_W = 15,  // 2^15 = 32768 >= 64*22*22 = 30976
    parameter integer WGT_ADDR_W = 17,  // 2^17 = 131072 >= 128*64*3*3 = 73728
    parameter integer OFM_ADDR_W = 16   // 2^16 = 65536 >= 128*20*20 = 51200
) (
    input  logic        clk,
    input  logic        rst_n,

    // config, sampled on `start`
    input  logic [7:0]  input_ch,
    input  logic [7:0]  output_ch,   // oc_range
    input  logic [7:0]  kernel_h,
    input  logic [7:0]  kernel_w,
    input  logic [8:0]  tile_h,
    input  logic [8:0]  tile_w,
    input  logic [2:0]  stride,

    input  logic        start,       // 1-cycle pulse: begin computing one tile
    output logic        done,        // 1-cycle pulse: tile result valid in OFM BRAM
    output logic        busy,

    // IFM BRAM port B (read-only)
    output logic [IFM_ADDR_W-1:0] ifm_addr,
    input  logic [7:0]            ifm_rdata,

    // WEIGHT BRAM port B (read-only)
    output logic [WGT_ADDR_W-1:0] wgt_addr,
    input  logic [7:0]            wgt_rdata,

    // OFM BRAM port B (write-only)
    output logic [OFM_ADDR_W-1:0] ofm_addr,
    output logic [31:0]           ofm_wdata,
    output logic                  ofm_we
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_LATCH,
        S_ADDR,
        S_MAC,
        S_WRITE,
        S_DONE
    } state_t;

    state_t state, state_n;

    // ------------------------------------------------------------
    // Latched config
    // ------------------------------------------------------------
    logic [7:0] input_ch_r, output_ch_r, kernel_h_r, kernel_w_r;
    logic [8:0] tile_h_r, tile_w_r;
    logic [2:0] stride_r;

    // Derived address-stride constants (computed once in S_LATCH)
    logic [15:0] khw_r;       // kernel_h_r * kernel_w_r
    logic [23:0] ic_khw_r;    // input_ch_r * khw_r
    logic [11:0] ifm_w_eff_r; // (tile_w_r-1)*stride_r + kernel_w_r
    logic [11:0] ifm_h_eff_r; // (tile_h_r-1)*stride_r + kernel_h_r
    logic [23:0] ifm_plane_r; // ifm_h_eff_r * ifm_w_eff_r
    logic [18:0] tile_hw_r;   // tile_h_r * tile_w_r

    // ------------------------------------------------------------
    // Loop counters
    // ------------------------------------------------------------
    logic [7:0] toc, ic, kh, kw;
    logic [8:0] toh, tow;

    // ------------------------------------------------------------
    // Accumulator
    // ------------------------------------------------------------
    logic signed [31:0] acc;
    logic signed [15:0] product;
    logic signed [31:0] acc_next;

    assign product = $signed(ifm_rdata) * $signed(wgt_rdata);
    assign acc_next = acc + {{16{product[15]}}, product};

    // ------------------------------------------------------------
    // "Last iteration" flags
    // ------------------------------------------------------------
    wire last_mac       = (ic  == input_ch_r  - 8'd1) &&
                           (kh  == kernel_h_r  - 8'd1) &&
                           (kw  == kernel_w_r  - 8'd1);

    wire last_tile_elem = (toc == output_ch_r - 8'd1) &&
                           (toh == tile_h_r - 9'd1) &&
                           (tow == tile_w_r - 9'd1);

    // ------------------------------------------------------------
    // Address generation (combinational, based on current counters
    // and the registers latched in S_LATCH)
    // ------------------------------------------------------------
    logic [31:0] ifm_addr_full, wgt_addr_full, ofm_addr_full;

    always_comb begin
        ifm_addr_full = ic * ifm_plane_r
                       + (({23'b0, toh} * stride_r) + kh) * ifm_w_eff_r
                       + (({23'b0, tow} * stride_r) + kw);

        wgt_addr_full = toc * ic_khw_r
                       + ic * khw_r
                       + kh * kernel_w_r
                       + kw;

        ofm_addr_full = toc * tile_hw_r
                       + toh * tile_w_r
                       + tow;
    end

    // ------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= state_n;
        end
    end

    always_comb begin
        state_n = state;
        unique case (state)
            S_IDLE:  state_n = start ? S_LATCH : S_IDLE;
            S_LATCH: state_n = S_ADDR;
            S_ADDR:  state_n = S_MAC;
            S_MAC:   state_n = last_mac ? S_WRITE : S_ADDR;
            S_WRITE: state_n = last_tile_elem ? S_DONE : S_ADDR;
            S_DONE:  state_n = S_IDLE;
            default: state_n = S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            input_ch_r  <= '0;
            output_ch_r <= '0;
            kernel_h_r  <= '0;
            kernel_w_r  <= '0;
            tile_h_r    <= '0;
            tile_w_r    <= '0;
            stride_r    <= '0;
            khw_r       <= '0;
            ic_khw_r    <= '0;
            ifm_w_eff_r <= '0;
            ifm_h_eff_r <= '0;
            ifm_plane_r <= '0;
            tile_hw_r   <= '0;
            toc <= '0; toh <= '0; tow <= '0;
            ic  <= '0; kh  <= '0; kw  <= '0;
            acc <= '0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        input_ch_r  <= input_ch;
                        output_ch_r <= output_ch;
                        kernel_h_r  <= kernel_h;
                        kernel_w_r  <= kernel_w;
                        tile_h_r    <= tile_h;
                        tile_w_r    <= tile_w;
                        stride_r    <= stride;
                        toc <= '0; toh <= '0; tow <= '0;
                        ic  <= '0; kh  <= '0; kw  <= '0;
                        acc <= '0;
                        busy <= 1'b1;
                    end
                end

                S_LATCH: begin
                    khw_r       <= kernel_h_r * kernel_w_r;
                    ic_khw_r    <= input_ch_r * (kernel_h_r * kernel_w_r);
                    ifm_w_eff_r <= (tile_w_r - 9'd1) * stride_r + kernel_w_r;
                    ifm_h_eff_r <= (tile_h_r - 9'd1) * stride_r + kernel_h_r;
                    // ifm_plane_r depends on ifm_w_eff_r/ifm_h_eff_r which are
                    // registered this same cycle, so compute its value directly
                    // from the combinational expressions (not the registers).
                    ifm_plane_r <= ((tile_h_r - 9'd1) * stride_r + kernel_h_r)
                                 * ((tile_w_r - 9'd1) * stride_r + kernel_w_r);
                    tile_hw_r   <= tile_h_r * tile_w_r;
                end

                S_ADDR: begin
                    // addresses driven combinationally this cycle; BRAMs
                    // register the read data, valid next cycle (S_MAC)
                end

                S_MAC: begin
                    acc <= acc_next;
                    if (!last_mac) begin
                        if (kw == kernel_w_r - 8'd1) begin
                            kw <= '0;
                            if (kh == kernel_h_r - 8'd1) begin
                                kh <= '0;
                                ic <= ic + 8'd1;
                            end else begin
                                kh <= kh + 8'd1;
                            end
                        end else begin
                            kw <= kw + 8'd1;
                        end
                    end
                end

                S_WRITE: begin
                    if (!last_tile_elem) begin
                        ic <= '0; kh <= '0; kw <= '0;
                        acc <= '0;
                        if (tow == tile_w_r - 9'd1) begin
                            tow <= '0;
                            if (toh == tile_h_r - 9'd1) begin
                                toh <= '0;
                                toc <= toc + 8'd1;
                            end else begin
                                toh <= toh + 9'd1;
                            end
                        end else begin
                            tow <= tow + 9'd1;
                        end
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------
    // BRAM port outputs
    // ------------------------------------------------------------
    assign ifm_addr = ifm_addr_full[IFM_ADDR_W-1:0];
    assign wgt_addr = wgt_addr_full[WGT_ADDR_W-1:0];
    assign ofm_addr = ofm_addr_full[OFM_ADDR_W-1:0];
    // `acc` already holds the final tile sum when entering S_WRITE (it was
    // updated with acc_next on the S_MAC -> S_WRITE transition).
    assign ofm_wdata = acc;
    assign ofm_we = (state == S_WRITE);

endmodule
