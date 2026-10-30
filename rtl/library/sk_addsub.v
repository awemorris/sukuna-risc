// ============================================================================
// Sukuna-RISC: sk_addsub Adder/Subtractor Primitive (Verilog 2005)
// Complies with design-rule.md
// Parameters:
//   - IMPL: "CARRY" (default: FPGA CARRY4), "LOGIC" (LUT), "DSP" (DSP48E1)
// ============================================================================

`include "sukuna_defines.vh"

module sk_addsub #(
  parameter WIDTH    = 64,
  parameter PIPELINE = 0,
  parameter IMPL     = "CARRY" // "CARRY", "LOGIC", "DSP"
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             sub_i,      // 0: Add, 1: Sub
  input  wire [WIDTH-1:0] a_i,
  input  wire [WIDTH-1:0] b_i,

  output wire [WIDTH-1:0] result_o,
  output wire             carry_borrow_o
);

  generate
    if (IMPL == "DSP") begin : gen_dsp
      `ifdef SYNTH_DESIGNWARE
      wire [WIDTH-1:0] dw_res;
      wire             dw_co;
      DW01_addsub #(.width(WIDTH)) u_dw_addsub (
        .A(a_i),
        .B(b_i),
        .CI(1'b0),
        .ADD_SUB(~sub_i),
        .SUM(dw_res),
        .CO(dw_co)
      );
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
          else         begin res_q <= dw_res;        cb_q <= dw_co; end
        end
        assign result_o = res_q; assign carry_borrow_o = cb_q;
      end else begin : gen_comb
        assign result_o = dw_res; assign carry_borrow_o = dw_co;
      end
      `elsif SYNTH_KINTEX7
      if (WIDTH <= 48 && PIPELINE >= 1) begin : gen_kintex7_dsp
        wire [29:0] dsp_a = (WIDTH > 18) ? {{(30-(WIDTH-18)){1'b0}}, b_i[WIDTH-1:18]} : 30'd0;
        wire [17:0] dsp_b = (WIDTH > 18) ? b_i[17:0] : {{(18-WIDTH){1'b0}}, b_i};
        wire [47:0] dsp_c = {{(48-WIDTH){1'b0}}, a_i};
        wire [47:0] dsp_p;
        wire [3:0]  dsp_co;

        DSP48E1 #(
          .ALUMODEREG (0),
          .AREG       (1),
          .BREG       (1),
          .CREG       (1),
          .PREG       (1),
          .USE_MULT   ("NONE"),
          .USE_SIMD   ("ONE48")
        ) u_dsp (
          .CLK(clk_i),
          .CEA1(1'b0), .CEA2(1'b1),
          .CEB1(1'b0), .CEB2(1'b1),
          .CEC(1'b1), .CED(1'b0), .CEAD(1'b0), .CEM(1'b0), .CEP(1'b1),
          .CEALUMODE(1'b1), .CECTRL(1'b1), .CEINMODE(1'b0), .CECARRYIN(1'b1),
          .RSTA(!rst_ni), .RSTB(!rst_ni), .RSTC(!rst_ni), .RSTP(!rst_ni),
          .RSTD(1'b0), .RSTM(1'b0), .RSTALLCARRYIN(!rst_ni), .RSTALUMODE(1'b0),
          .RSTCTRL(1'b0), .RSTINMODE(1'b0),
          .A(dsp_a), .B(dsp_b), .C(dsp_c), .D(25'd0),
          .INMODE(5'd0),
          .OPMODE(7'b0110011), // Z=C, X=A:B
          .ALUMODE(sub_i ? 4'b0011 : 4'b0000), // sub: Z - (A:B), add: Z + (A:B)
          .CARRYINSEL(3'b000),
          .CARRYIN(1'b0),
          .BCIN(18'd0), .ACIN(30'd0), .PCIN(48'd0),
          .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
          .P(dsp_p),
          .CARRYOUT(dsp_co),
          .ACOUT(), .BCOUT(), .PCOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(),
          .OVERFLOW(), .UNDERFLOW(), .PATTERNDETECT(), .PATTERNBDETECT()
        );
        assign result_o       = dsp_p[WIDTH-1:0];
        assign carry_borrow_o = dsp_co[3];
      end else begin : gen_dsp_wide
        (* use_dsp = "yes" *)
        wire [WIDTH-1:0] b_eff = sub_i ? ~b_i : b_i;
        wire [WIDTH:0]   dsp_comb = a_i + b_eff + {{WIDTH{1'b0}}, sub_i};
        if (PIPELINE) begin : gen_pipe
          reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
            else         begin res_q <= dsp_comb[WIDTH-1:0]; cb_q <= dsp_comb[WIDTH]; end
          end
          assign result_o = res_q; assign carry_borrow_o = cb_q;
        end else begin : gen_comb
          assign result_o = dsp_comb[WIDTH-1:0]; assign carry_borrow_o = dsp_comb[WIDTH];
        end
      end
      `else
      (* use_dsp = "yes" *)
      wire [WIDTH-1:0] b_eff = sub_i ? ~b_i : b_i;
      wire [WIDTH:0]   dsp_comb = a_i + b_eff + {{WIDTH{1'b0}}, sub_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
          else         begin res_q <= dsp_comb[WIDTH-1:0]; cb_q <= dsp_comb[WIDTH]; end
        end
        assign result_o = res_q; assign carry_borrow_o = cb_q;
      end else begin : gen_comb
        assign result_o = dsp_comb[WIDTH-1:0]; assign carry_borrow_o = dsp_comb[WIDTH];
      end
      `endif

    end else if (IMPL == "CARRY") begin : gen_carry
      `ifdef SYNTH_DESIGNWARE
      wire [WIDTH-1:0] dw_res;
      wire             dw_co;
      DW01_addsub #(.width(WIDTH)) u_dw_addsub (
        .A(a_i),
        .B(b_i),
        .CI(1'b0),
        .ADD_SUB(~sub_i),
        .SUM(dw_res),
        .CO(dw_co)
      );
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
          else         begin res_q <= dw_res;        cb_q <= dw_co; end
        end
        assign result_o = res_q; assign carry_borrow_o = cb_q;
      end else begin : gen_comb
        assign result_o = dw_res; assign carry_borrow_o = dw_co;
      end
      `else
      // Uses FPGA dedicated slice carry chain (CARRY4)
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] b_effective = sub_i ? ~b_i : b_i;
      wire [WIDTH:0]   carry_comb  = a_i + b_effective + {{WIDTH{1'b0}}, sub_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
          else         begin res_q <= carry_comb[WIDTH-1:0]; cb_q <= carry_comb[WIDTH]; end
        end
        assign result_o = res_q; assign carry_borrow_o = cb_q;
      end else begin : gen_comb
        assign result_o = carry_comb[WIDTH-1:0]; assign carry_borrow_o = carry_comb[WIDTH];
      end
      `endif

    end else begin : gen_logic
      // Pure LUT Logic (ASIC standard cell / FPGA LUT gate logic)
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] b_effective = sub_i ? ~b_i : b_i;
      wire [WIDTH:0]   logic_comb  = a_i + b_effective + {{WIDTH{1'b0}}, sub_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin res_q <= {WIDTH{1'b0}}; cb_q <= 1'b0; end
          else         begin res_q <= logic_comb[WIDTH-1:0]; cb_q <= logic_comb[WIDTH]; end
        end
        assign result_o = res_q; assign carry_borrow_o = cb_q;
      end else begin : gen_comb
        assign result_o = logic_comb[WIDTH-1:0]; assign carry_borrow_o = logic_comb[WIDTH];
      end
    end
  endgenerate

endmodule
