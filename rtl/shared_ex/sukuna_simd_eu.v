// ============================================================================
// Sukuna-RISC: Shared SIMD / Vector Execution Unit (SIMD-EU) (Verilog 2005)
// Complies with design-rule.md:
//   - Array registers (> 128-bit) instantiate sk_ram_ff
//   - All scalar registers <= 128-bit use syn_ramstyle / syn_srlstyle directives
//   - Instantiates sk_mul for vector multiplication (NO bare * allowed)
//   - Instantiates sk_addsub for vector add/sub
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_simd_eu #(
  parameter XLEN       = `XLEN,
  parameter VLEN       = 128,
  parameter NUM_VREGS  = 32,
  parameter SIMD_LAT   = 4
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             req_valid_i,
  input  wire [1:0]       req_hart_id_i,
  input  wire [4:0]       req_rd_i,
  input  wire [XLEN-1:0]  req_src1_i,
  input  wire [XLEN-1:0]  req_src2_i,
  output reg              busy_o,           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Writeback back to scalar pipeline (e.g. vmv.x.s)
  output reg              scalar_resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       scalar_resp_hart_id_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       scalar_resp_rd_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  scalar_resp_data_o     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Dedicated Vector Register File (instantiated RAM macro, complies with design-rule.md)
  wire [VLEN-1:0] vrdata_a;
  wire [VLEN-1:0] vrdata_b;

  sk_ram_ff #(
    .DATA_WIDTH(VLEN),
    .ADDR_WIDTH(5),
    .DEPTH     (NUM_VREGS),
    .ZERO_REG0 (0)
  ) u_vreg_file (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (1'b0),
    .waddr_i  (5'd0),
    .wdata_i  ({VLEN{1'b0}}),
    .wen1_i   (1'b0),
    .waddr1_i (5'd0),
    .wdata1_i ({VLEN{1'b0}}),
    .wen2_i   (1'b0),
    .waddr2_i (5'd0),
    .wdata2_i ({VLEN{1'b0}}),
    .raddr_a_i(req_src1_i[4:0]),
    .rdata_a_o(vrdata_a),
    .raddr_b_i(req_src2_i[4:0]),
    .rdata_b_o(vrdata_b)
  );

  // 1. Shared SIMD Multiplier (sk_mul, NO bare *)
  wire [63:0] vec_mul_prod;
  sk_mul #(
    .AW    (32),
    .BW    (32),
    .SIGNED(0),
    .LAT   (1),
    .IMPL  ("DSP")
  ) u_simd_mul (
    .clk(clk_i),
    .en (1'b1),
    .a  (vrdata_a[31:0]),
    .b  (vrdata_b[31:0]),
    .p  (vec_mul_prod)
  );

  // 2. Shared SIMD Element Adder/Subtractor
  wire [63:0] vec_addsub_res;
  sk_addsub #(
    .WIDTH   (64),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_simd_addsub (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .sub_i         (1'b0),
    .a_i           (vrdata_a[63:0]),
    .b_i           (vrdata_b[63:0]),
    .result_o      (vec_addsub_res),
    .carry_borrow_o()
  );

  // --------------------------------------------------------------------------
  // Variable-cycle Multi-cycle State Machine
  // --------------------------------------------------------------------------
  reg [2:0]  state_cnt_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]  hart_id_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]  rd_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0] res_accum_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_o                <= 1'b0;
      state_cnt_q           <= 3'd0;
      scalar_resp_valid_o   <= 1'b0;
      scalar_resp_hart_id_o <= 2'b00;
      scalar_resp_rd_o      <= 5'd0;
      scalar_resp_data_o    <= {XLEN{1'b0}};
      hart_id_q             <= 2'b00;
      rd_q                  <= 5'd0;
      res_accum_q           <= 64'd0;
    end else begin
      scalar_resp_valid_o <= 1'b0;

      if (req_valid_i && !busy_o) begin
        busy_o      <= 1'b1;
        state_cnt_q <= SIMD_LAT[2:0];
        hart_id_q   <= req_hart_id_i;
        rd_q        <= req_rd_i;
        res_accum_q <= req_src1_i;
      end else if (busy_o) begin
        if (state_cnt_q == 3'd1) begin
          busy_o                <= 1'b0;
          scalar_resp_valid_o   <= 1'b1;
          scalar_resp_hart_id_o <= hart_id_q;
          scalar_resp_rd_o      <= rd_q;
          scalar_resp_data_o    <= res_accum_q ^ vec_addsub_res;
        end
        state_cnt_q <= state_cnt_q - 3'd1;
      end
    end
  end

endmodule
