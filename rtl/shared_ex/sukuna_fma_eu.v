// ============================================================================
// Sukuna-RISC: Shared FMA Execution Unit (FMA-EU) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Fused Multiply-Add: (src1 * src2) + src3
//   - Resource sharing:
//     * sk_mul for multiplication (NO bare *)
//     * sk_addsub for accumulation (+ src3)
//   - Variable-cycle multicycle execution with busy handshake
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fma_eu #(
  parameter XLEN    = `XLEN,
  parameter FMA_LAT = 4
)(
  input  wire            clk_i,
  input  wire            rst_ni,

  input  wire            req_valid_i,
  input  wire [1:0]      req_hart_id_i,
  input  wire [4:0]      req_rd_i,
  input  wire [XLEN-1:0] req_src1_i,
  input  wire [XLEN-1:0] req_src2_i,
  input  wire [XLEN-1:0] req_src3_i,
  output wire            busy_o,

  output reg             resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]      resp_hart_id_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]      resp_rd_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0] resp_data_o     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // 1. Shared Multiplier Instance (sk_mul)
  wire [105:0] fma_prod;
  sk_mul #(
    .AW    (53),
    .BW    (53),
    .SIGNED(0),
    .LAT   (1),
    .IMPL  ("DSP")
  ) u_fma_mul (
    .clk(clk_i),
    .en (1'b1),
    .a  (req_src1_i[52:0]),
    .b  (req_src2_i[52:0]),
    .p  (fma_prod)
  );

  // 2. Shared Accumulator Instance (sk_addsub)
  reg [XLEN-1:0] add_operand_a_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] add_operand_b_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [XLEN-1:0] fma_accum_res;

  sk_addsub #(
    .WIDTH   (XLEN),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_fma_add (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .sub_i         (1'b0),
    .a_i           (add_operand_a_q),
    .b_i           (add_operand_b_q),
    .result_o      (fma_accum_res),
    .carry_borrow_o()
  );

  // --------------------------------------------------------------------------
  // Variable-cycle Multi-cycle Engine
  // --------------------------------------------------------------------------
  reg [2:0] state_cnt_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       busy_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0] hart_id_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0] rd_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign busy_o = busy_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q            <= 1'b0;
      state_cnt_q       <= 3'd0;
      resp_valid_o      <= 1'b0;
      resp_hart_id_o    <= 2'b00;
      resp_rd_o         <= 5'd0;
      resp_data_o       <= {XLEN{1'b0}};
      hart_id_q         <= 2'b00;
      rd_q              <= 5'd0;
      add_operand_a_q   <= {XLEN{1'b0}};
      add_operand_b_q   <= {XLEN{1'b0}};
    end else begin
      resp_valid_o <= 1'b0;

      if (req_valid_i && !busy_q) begin
        busy_q          <= 1'b1;
        state_cnt_q     <= FMA_LAT[2:0];
        hart_id_q       <= req_hart_id_i;
        rd_q            <= req_rd_i;
        add_operand_b_q <= req_src3_i;
      end else if (busy_q) begin
        if (state_cnt_q == 3'd2) begin
          add_operand_a_q <= {11'd0, fma_prod[105:53]};
        end else if (state_cnt_q == 3'd1) begin
          busy_q         <= 1'b0;
          resp_valid_o   <= 1'b1;
          resp_hart_id_o <= hart_id_q;
          resp_rd_o      <= rd_q;
          resp_data_o    <= fma_accum_res;
        end
        state_cnt_q <= state_cnt_q - 3'd1;
      end
    end
  end

endmodule
