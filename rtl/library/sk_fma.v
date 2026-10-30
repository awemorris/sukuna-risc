// ============================================================================
// Fused Multiply-Add (FMA) Primitive Abstraction (Verilog 2005)
// Complies with design-rule.md
// Parameters:
//   - IMPL: "DSP" (default: hardware DSP48E1), "CARRY" (LUT/Carry4), "LOGIC" (LUT)
// Calculates:
//   result_o = (a_i * b_i) + (sub_c_i ? -c_i : c_i)
// ============================================================================

`include "sukuna_defines.vh"

module sk_fma #(
  parameter A_WIDTH         = 32,
  parameter B_WIDTH         = 32,
  parameter C_WIDTH         = 64,
  parameter OUT_WIDTH       = 64,
  parameter PIPELINE_STAGES = 2,
  parameter IMPL            = "DSP" // "DSP", "CARRY", "LOGIC"
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  input  wire                  sub_c_i,
  input  wire [A_WIDTH-1:0]    a_i,
  input  wire [B_WIDTH-1:0]    b_i,
  input  wire [C_WIDTH-1:0]    c_i,

  output wire [OUT_WIDTH-1:0]  result_o
);

  generate
    if (IMPL == "DSP") begin : gen_dsp
      `ifdef SYNTH_DESIGNWARE
        wire [A_WIDTH+B_WIDTH-1:0] dw_c = sub_c_i ? -c_i : c_i;
        wire [A_WIDTH+B_WIDTH-1:0] dw_mac_out;
        DW02_mac #(.A_width(A_WIDTH), .B_width(B_WIDTH)) u_dw_mac (
          .A(a_i),
          .B(b_i),
          .C(dw_c),
          .TC(1'b0),
          .MAC(dw_mac_out)
        );
        if (PIPELINE_STAGES == 0) begin : gen_p0
          assign result_o = dw_mac_out[OUT_WIDTH-1:0];
        end else if (PIPELINE_STAGES == 1) begin : gen_p1
          reg [OUT_WIDTH-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) r1 <= {OUT_WIDTH{1'b0}};
            else         r1 <= dw_mac_out[OUT_WIDTH-1:0];
          end
          assign result_o = r1;
        end else begin : gen_p2
          reg [OUT_WIDTH-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg [OUT_WIDTH-1:0] r2; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin r1 <= {OUT_WIDTH{1'b0}}; r2 <= {OUT_WIDTH{1'b0}}; end
            else         begin r1 <= dw_mac_out[OUT_WIDTH-1:0]; r2 <= r1; end
          end
          assign result_o = r2;
        end
      `elsif SYNTH_KINTEX7
      if (A_WIDTH <= 25 && B_WIDTH <= 18 && C_WIDTH <= 48 && OUT_WIDTH <= 48) begin : gen_kintex7_dsp_fma
        wire [29:0] dsp_a = {{(30-A_WIDTH){1'b0}}, a_i};
        wire [17:0] dsp_b = {{(18-B_WIDTH){1'b0}}, b_i};
        wire [47:0] dsp_c = {{(48-C_WIDTH){1'b0}}, c_i};
        wire [47:0] dsp_p;

        DSP48E1 #(
          .ALUMODEREG      (0),
          .AREG            (PIPELINE_STAGES >= 2 ? 1 : 0),
          .BREG            (PIPELINE_STAGES >= 2 ? 1 : 0),
          .CREG            (PIPELINE_STAGES >= 2 ? 1 : 0),
          .DREG            (0),
          .MREG            (PIPELINE_STAGES >= 2 ? 1 : 0),
          .PREG            (PIPELINE_STAGES >= 1 ? 1 : 0),
          .USE_MULT        ("MULTIPLY"),
          .USE_SIMD        ("ONE48")
        ) u_dsp48e1_fma (
          .CLK             (clk_i),
          .CEA1            (1'b0),
          .CEA2            (1'b1),
          .CEB1            (1'b0),
          .CEB2            (1'b1),
          .CEC             (1'b1),
          .CED             (1'b0),
          .CEAD            (1'b0),
          .CEM             (1'b1),
          .CEP             (1'b1),
          .CEALUMODE       (1'b1),
          .CECTRL          (1'b1),
          .CEINMODE        (1'b0),
          .CECARRYIN       (1'b0),
          .RSTA            (!rst_ni),
          .RSTB            (!rst_ni),
          .RSTC            (!rst_ni),
          .RSTD            (1'b0),
          .RSTM            (!rst_ni),
          .RSTP            (!rst_ni),
          .RSTALLCARRYIN   (1'b0),
          .RSTALUMODE      (1'b0),
          .RSTCTRL         (1'b0),
          .RSTINMODE       (1'b0),
          .A               (dsp_a),
          .B               (dsp_b),
          .C               (dsp_c),
          .D               (25'd0),
          .INMODE          (5'b00000),
          .OPMODE          (7'b0110101), // Z=C (011), X/Y=M (0101) -> P = (A*B) + C
          .ALUMODE         (sub_c_i ? 4'b0001 : 4'b0000),
          .CARRYINSEL      (3'b000),
          .CARRYIN         (1'b0),
          .BCIN            (18'd0),
          .ACIN            (30'd0),
          .PCIN            (48'd0),
          .CARRYCASCIN     (1'b0),
          .MULTSIGNIN      (1'b0),
          .P               (dsp_p),
          .ACOUT           (),
          .BCOUT           (),
          .PCOUT           (),
          .CARRYOUT        (),
          .CARRYCASCOUT    (),
          .MULTSIGNOUT     (),
          .OVERFLOW        (),
          .UNDERFLOW       (),
          .PATTERNDETECT   (),
          .PATTERNBDETECT  ()
        );
        assign result_o = dsp_p[OUT_WIDTH-1:0];

      end else begin : gen_kintex7_dsp_fma_wide
        wire [A_WIDTH+B_WIDTH-1:0] mult_res;
        sk_mul #(
          .AW    (A_WIDTH),
          .BW    (B_WIDTH),
          .SIGNED(0),
          .LAT   (PIPELINE_STAGES >= 2 ? 1 : 0),
          .IMPL  ("DSP")
        ) u_fma_mul (
          .clk(clk_i),
          .en (1'b1),
          .a  (a_i),
          .b  (b_i),
          .p  (mult_res)
        );

        wire [OUT_WIDTH-1:0] c_term = sub_c_i ? (-c_i) : c_i;
        wire [OUT_WIDTH-1:0] comb_fma = {{ (OUT_WIDTH-(A_WIDTH+B_WIDTH)){1'b0} }, mult_res} + c_term;

        if (PIPELINE_STAGES == 0) begin : gen_fma_comb
          assign result_o = comb_fma;
        end else begin : gen_fma_pipe
          reg [OUT_WIDTH-1:0] fma_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) fma_q <= {OUT_WIDTH{1'b0}};
            else         fma_q <= comb_fma;
          end
          assign result_o = fma_q;
        end
      end
      `else
      // Generic DSP FMA
      wire [A_WIDTH+B_WIDTH-1:0] mult_res;
      sk_mul #(
        .AW    (A_WIDTH),
        .BW    (B_WIDTH),
        .SIGNED(0),
        .LAT   (PIPELINE_STAGES >= 2 ? 1 : 0),
        .IMPL  ("DSP")
      ) u_fma_mul (
        .clk(clk_i),
        .en (1'b1),
        .a  (a_i),
        .b  (b_i),
        .p  (mult_res)
      );

      wire [OUT_WIDTH-1:0] c_term = sub_c_i ? (-c_i) : c_i;
      wire [OUT_WIDTH-1:0] comb_fma = {{ (OUT_WIDTH-(A_WIDTH+B_WIDTH)){1'b0} }, mult_res} + c_term;

      if (PIPELINE_STAGES == 0) begin : gen_fma_comb
        assign result_o = comb_fma;
      end else begin : gen_fma_pipe
        reg [OUT_WIDTH-1:0] fma_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) fma_q <= {OUT_WIDTH{1'b0}};
          else         fma_q <= comb_fma;
        end
        assign result_o = fma_q;
      end
      `endif

    end else if (IMPL == "CARRY") begin : gen_carry
      // FMA using Carry chains (NO DSP)
      wire [A_WIDTH+B_WIDTH-1:0] mult_res;
      sk_mul #(
        .AW    (A_WIDTH),
        .BW    (B_WIDTH),
        .SIGNED(0),
        .LAT   (PIPELINE_STAGES >= 2 ? 1 : 0),
        .IMPL  ("CARRY")
      ) u_fma_mul (
        .clk(clk_i),
        .en (1'b1),
        .a  (a_i),
        .b  (b_i),
        .p  (mult_res)
      );

      wire [OUT_WIDTH-1:0] c_term = sub_c_i ? (-c_i) : c_i;
      wire [OUT_WIDTH-1:0] comb_fma = {{ (OUT_WIDTH-(A_WIDTH+B_WIDTH)){1'b0} }, mult_res} + c_term;

      if (PIPELINE_STAGES == 0) begin : gen_fma_comb
        assign result_o = comb_fma;
      end else begin : gen_fma_pipe
        reg [OUT_WIDTH-1:0] fma_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) fma_q <= {OUT_WIDTH{1'b0}};
          else         fma_q <= comb_fma;
        end
        assign result_o = fma_q;
      end

    end else begin : gen_logic
      // FMA using pure LUT Logic (NO DSP)
      wire [A_WIDTH+B_WIDTH-1:0] mult_res;
      sk_mul #(
        .AW    (A_WIDTH),
        .BW    (B_WIDTH),
        .SIGNED(0),
        .LAT   (PIPELINE_STAGES >= 2 ? 1 : 0),
        .IMPL  ("LOGIC")
      ) u_fma_mul (
        .clk(clk_i),
        .en (1'b1),
        .a  (a_i),
        .b  (b_i),
        .p  (mult_res)
      );

      wire [OUT_WIDTH-1:0] c_term = sub_c_i ? (-c_i) : c_i;
      wire [OUT_WIDTH-1:0] comb_fma = {{ (OUT_WIDTH-(A_WIDTH+B_WIDTH)){1'b0} }, mult_res} + c_term;

      if (PIPELINE_STAGES == 0) begin : gen_fma_comb
        assign result_o = comb_fma;
      end else begin : gen_fma_pipe
        reg [OUT_WIDTH-1:0] fma_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) fma_q <= {OUT_WIDTH{1'b0}};
          else         fma_q <= comb_fma;
        end
        assign result_o = fma_q;
      end
    end
  endgenerate

endmodule
