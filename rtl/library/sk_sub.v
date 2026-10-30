// ============================================================================
// Sukuna-RISC: sk_sub Subtractor Primitive (Verilog 2005)
// Complies with design-rule.md
// Parameters:
//   - IMPL: "CARRY" (default: FPGA CARRY4), "LOGIC" (LUT), "DSP" (DSP48E1)
// ============================================================================

`include "sukuna_defines.vh"

module sk_sub #(
  parameter WIDTH    = 64,
  parameter PIPELINE = 0,
  parameter IMPL     = "CARRY" // "CARRY", "LOGIC", "DSP"
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             bin_i,
  input  wire [WIDTH-1:0] a_i,
  input  wire [WIDTH-1:0] b_i,

  output wire [WIDTH-1:0] diff_o,
  output wire             bout_o
);

  generate
    if (IMPL == "DSP") begin : gen_dsp
      `ifdef SYNTH_DESIGNWARE
      wire [WIDTH-1:0] dw_diff;
      wire             dw_co;
      DW01_sub #(.width(WIDTH)) u_dw_sub (
        .A(a_i),
        .B(b_i),
        .CI(bin_i),
        .DIFF(dw_diff),
        .CO(dw_co)
      );
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
          else         begin diff_q <= dw_diff;       bout_q <= dw_co;  end
        end
        assign diff_o = diff_q; assign bout_o = bout_q;
      end else begin : gen_comb
        assign diff_o = dw_diff; assign bout_o = dw_co;
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
          .ALUMODE(4'b0011),   // Z - (A:B)
          .CARRYINSEL(3'b000),
          .CARRYIN(bin_i),
          .BCIN(18'd0), .ACIN(30'd0), .PCIN(48'd0),
          .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
          .P(dsp_p),
          .CARRYOUT(dsp_co),
          .ACOUT(), .BCOUT(), .PCOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(),
          .OVERFLOW(), .UNDERFLOW(), .PATTERNDETECT(), .PATTERNBDETECT()
        );
        assign diff_o = dsp_p[WIDTH-1:0];
        assign bout_o = ~dsp_co[3];
      end else begin : gen_dsp_wide
        (* use_dsp = "yes" *)
        wire [WIDTH:0] dsp_comb = {1'b0, a_i} - {1'b0, b_i} - {{WIDTH{1'b0}}, bin_i};
        if (PIPELINE) begin : gen_pipe
          reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
            else         begin diff_q <= dsp_comb[WIDTH-1:0]; bout_q <= dsp_comb[WIDTH]; end
          end
          assign diff_o = diff_q; assign bout_o = bout_q;
        end else begin : gen_comb
          assign diff_o = dsp_comb[WIDTH-1:0]; assign bout_o = dsp_comb[WIDTH];
        end
      end
      `else
      (* use_dsp = "yes" *)
      wire [WIDTH:0] dsp_comb = {1'b0, a_i} - {1'b0, b_i} - {{WIDTH{1'b0}}, bin_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
          else         begin diff_q <= dsp_comb[WIDTH-1:0]; bout_q <= dsp_comb[WIDTH]; end
        end
        assign diff_o = diff_q; assign bout_o = bout_q;
      end else begin : gen_comb
        assign diff_o = dsp_comb[WIDTH-1:0]; assign bout_o = dsp_comb[WIDTH];
      end
      `endif

    end else if (IMPL == "CARRY") begin : gen_carry
      `ifdef SYNTH_DESIGNWARE
      wire [WIDTH-1:0] dw_diff;
      wire             dw_co;
      DW01_sub #(.width(WIDTH)) u_dw_sub (
        .A(a_i),
        .B(b_i),
        .CI(bin_i),
        .DIFF(dw_diff),
        .CO(dw_co)
      );
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
          else         begin diff_q <= dw_diff;       bout_q <= dw_co;  end
        end
        assign diff_o = diff_q; assign bout_o = bout_q;
      end else begin : gen_comb
        assign diff_o = dw_diff; assign bout_o = dw_co;
      end
      `else
      // Uses FPGA dedicated slice carry chain (CARRY4)
      (* use_dsp = "no" *)
      wire [WIDTH:0] carry_comb = {1'b0, a_i} - {1'b0, b_i} - {{WIDTH{1'b0}}, bin_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
          else         begin diff_q <= carry_comb[WIDTH-1:0]; bout_q <= carry_comb[WIDTH]; end
        end
        assign diff_o = diff_q; assign bout_o = bout_q;
      end else begin : gen_comb
        assign diff_o = carry_comb[WIDTH-1:0]; assign bout_o = carry_comb[WIDTH];
      end
      `endif

    end else begin : gen_logic
      // Pure LUT Logic (ASIC standard cell / FPGA LUT gate logic)
      (* use_dsp = "no" *)
      wire [WIDTH:0] logic_comb = {1'b0, a_i} - {1'b0, b_i} - {{WIDTH{1'b0}}, bin_i};
      if (PIPELINE) begin : gen_pipe
        reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin diff_q <= {WIDTH{1'b0}}; bout_q <= 1'b0; end
          else         begin diff_q <= logic_comb[WIDTH-1:0]; bout_q <= logic_comb[WIDTH]; end
        end
        assign diff_o = diff_q; assign bout_o = bout_q;
      end else begin : gen_comb
        assign diff_o = logic_comb[WIDTH-1:0]; assign bout_o = logic_comb[WIDTH];
      end
    end
  endgenerate

endmodule
