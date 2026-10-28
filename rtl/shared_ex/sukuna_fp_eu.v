// ============================================================================
// Sukuna-RISC: Shared FP Execution Unit (FP-EU) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Variable-cycle latency execution (configurable multicycle state machine)
//   - Resource sharing:
//     * Single sk_mul instantiated for FP multiplication (NO bare * allowed)
//     * Single sk_addsub instantiated for FP addition / subtraction
//   - Busy handshake backpressure to shared arbiter
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fp_eu #(
  parameter XLEN   = `XLEN,
  parameter FP_LAT = 3
)(
  input  wire            clk_i,
  input  wire            rst_ni,

  input  wire            req_valid_i,
  input  wire [1:0]      req_hart_id_i,
  input  wire [4:0]      req_rd_i,
  input  wire [XLEN-1:0] req_src1_i,
  input  wire [XLEN-1:0] req_src2_i,
  input  wire            req_is_mul_i,
  input  wire            req_is_sub_i,
  output wire            busy_o,

  output reg             resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]      resp_hart_id_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]      resp_rd_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0] resp_data_o     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Shared Arithmetic Core Instances
  // --------------------------------------------------------------------------
  // 1. Shared Mantissa Multiplier (53-bit for FP64 DP mantissa)
  wire [105:0] fp_mant_prod;
  sk_mul #(
    .AW    (53),
    .BW    (53),
    .SIGNED(0),
    .LAT   (1),
    .IMPL  ("DSP")
  ) u_fp_mul (
    .clk(clk_i),
    .en (1'b1),
    .a  (req_src1_i[52:0]),
    .b  (req_src2_i[52:0]),
    .p  (fp_mant_prod)
  );

  // 2. Shared Mantissa Adder/Subtractor
  wire [XLEN-1:0] fp_addsub_res;
  wire            fp_addsub_cb;
  sk_addsub #(
    .WIDTH   (XLEN),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_fp_addsub (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .sub_i         (req_is_sub_i),
    .a_i           (req_src1_i),
    .b_i           (req_src2_i),
    .result_o      (fp_addsub_res),
    .carry_borrow_o(fp_addsub_cb)
  );

  // --------------------------------------------------------------------------
  // Multi-cycle State Machine
  // --------------------------------------------------------------------------
  reg [2:0]      state_cnt_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            busy_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]      hart_id_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]      rd_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            is_mul_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] final_res_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign busy_o = busy_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q         <= 1'b0;
      state_cnt_q    <= 3'd0;
      resp_valid_o   <= 1'b0;
      resp_hart_id_o <= 2'b00;
      resp_rd_o      <= 5'd0;
      resp_data_o    <= {XLEN{1'b0}};
      hart_id_q      <= 2'b00;
      rd_q           <= 5'd0;
      is_mul_q       <= 1'b0;
      final_res_q    <= {XLEN{1'b0}};
    end else begin
      resp_valid_o <= 1'b0;

      if (req_valid_i && !busy_q) begin
        busy_q      <= 1'b1;
        state_cnt_q <= FP_LAT[2:0];
        hart_id_q   <= req_hart_id_i;
        rd_q        <= req_rd_i;
        is_mul_q    <= req_is_mul_i;
      end else if (busy_q) begin
        if (state_cnt_q == 3'd1) begin
          busy_q         <= 1'b0;
          resp_valid_o   <= 1'b1;
          resp_hart_id_o <= hart_id_q;
          resp_rd_o      <= rd_q;
          resp_data_o    <= is_mul_q ? {11'd0, fp_mant_prod[105:53]} : fp_addsub_res;
        end
        state_cnt_q <= state_cnt_q - 3'd1;
      end
    end
  end

endmodule
