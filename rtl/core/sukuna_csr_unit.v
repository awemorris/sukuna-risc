// ============================================================================
// Per-Hart Control and Status Register (CSR) Unit (Verilog 2005)
// Complies with design-rule.md
// Implements RISC-V Privileged Architecture (Machine & Supervisor Modes):
//   - CSRs: mstatus, misa, medeleg, mideleg, mie, mtvec, mscratch, mepc,
//           mcause, mtval, mip, mhartid
//   - S-mode CSRs: sstatus, sie, sip, stvec, sscratch, sepc, scause, stval, satp
//   - Trap entry (M-mode / S-mode delegated) and return (MRET / SRET)
//   - WFI (Wait For Interrupt) low-power sleep / wakeup
//   - Privilege check (U / S / M) and Illegal Instruction generation
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_csr_unit #(
  parameter HART_ID = 0,
  parameter XLEN    = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // --------------------------------------------------------------------------
  // Pipeline CSR Access Interface (Lane 0 only, in-order)
  // --------------------------------------------------------------------------
  input  wire                   csr_req_valid_i,
  input  wire [11:0]            csr_addr_i,
  input  wire [1:0]             csr_op_i,        // 2'b01: RW, 2'b10: RS, 2'b11: RC
  input  wire                   csr_wen_i,       // 1 if write side-effects should take place
  input  wire [XLEN-1:0]        csr_wdata_i,
  output reg  [XLEN-1:0]        csr_rdata_o,
  output wire                   csr_illegal_o,

  // --------------------------------------------------------------------------
  // Interrupt Signals from CLINT / PLIC
  // --------------------------------------------------------------------------
  input  wire                   meip_i,          // Machine External Interrupt
  input  wire                   seip_i,          // Supervisor External Interrupt
  input  wire                   mtip_i,          // Machine Timer Interrupt
  input  wire                   msip_i,          // Machine Software Interrupt

  // --------------------------------------------------------------------------
  // Trap / Exception / Privileged Instruction Interface from Pipeline
  // --------------------------------------------------------------------------
  input  wire                   exception_valid_i,
  input  wire [5:0]             exception_cause_i,
  input  wire [XLEN-1:0]        exception_pc_i,
  input  wire [XLEN-1:0]        exception_tval_i,

  input  wire                   mret_valid_i,
  input  wire                   sret_valid_i,
  input  wire                   wfi_valid_i,
  input  wire                   sfence_valid_i,

  // --------------------------------------------------------------------------
  // Control outputs to Frontend / MMU / Pipeline
  // --------------------------------------------------------------------------
  output wire                   trap_flush_o,
  output reg  [XLEN-1:0]        trap_target_pc_o,
  output reg  [XLEN-1:0]        satp_o,          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]             priv_mode_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */ // 11: M, 01: S, 00: U
  output wire                   sfence_flush_o,
  output reg                    wfi_sleep_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Asynchronous interrupt notification to Hazard Unit
  output wire                   interrupt_pending_o,
  output wire [5:0]             interrupt_cause_o
);

  // --------------------------------------------------------------------------
  // CSR Register Storage
  // --------------------------------------------------------------------------
  // Machine-mode registers
  reg [XLEN-1:0] mstatus_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [15:0]     medeleg_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [15:0]     mideleg_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [11:0]     mie_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mtvec_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mscratch_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mepc_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mcause_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mtval_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Supervisor-mode registers
  reg [XLEN-1:0] stvec_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] sscratch_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] sepc_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] scause_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] stval_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Software interrupt pending bit for S-mode
  reg ssip_q;               /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // MIP & MIE Bitmap Definitions
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] mip_wire = {
    {(XLEN-12){1'b0}},
    meip_i,  // 11: MEIP
    1'b0,    // 10: Reserved
    seip_i,  //  9: SEIP
    1'b0,    //  8: Reserved
    mtip_i,  //  7: MTIP
    1'b0,    //  6: Reserved
    1'b0,    //  5: STIP (via mtimecmp)
    1'b0,    //  4: Reserved
    msip_i,  //  3: MSIP
    1'b0,    //  2: Reserved
    ssip_q,  //  1: SSIP
    1'b0     //  0: Reserved
  };

  wire [XLEN-1:0] mie_wire = {{(XLEN-12){1'b0}}, mie_q};

  // S-mode view of status, ie, ip
  wire [XLEN-1:0] sstatus_wire = {
    mstatus_q[63],           // SD
    {(XLEN-35){1'b0}},
    mstatus_q[33:32],        // UXL
    {(32-19){1'b0}},
    mstatus_q[19],           // MXR
    mstatus_q[18],           // SUM
    1'b0,                    // Reserved
    mstatus_q[15:13],        // XS, FS
    4'b0000,
    mstatus_q[8],            // SPP
    1'b0,
    mstatus_q[5],            // SPIE
    2'b00,
    mstatus_q[1],            // SIE
    1'b0
  };

  wire [XLEN-1:0] sie_wire = mie_wire & {{(XLEN-16){1'b0}}, mideleg_q};
  wire [XLEN-1:0] sip_wire = mip_wire & {{(XLEN-16){1'b0}}, mideleg_q};

  // --------------------------------------------------------------------------
  // Privilege Level & Legality Checking
  // --------------------------------------------------------------------------
  // CSR address bits [9:8] define the minimum privilege required:
  // 00: User, 01: Supervisor, 11: Machine
  wire [1:0] csr_min_priv = csr_addr_i[9:8];
  wire       csr_read_only = (csr_addr_i[11:10] == 2'b11);

  wire priv_insufficient = (priv_mode_o < csr_min_priv);
  wire write_to_ro       = csr_wen_i && csr_read_only;

  reg csr_exists;
  always @(*) begin
    case (csr_addr_i)
      12'h300, 12'h301, 12'h302, 12'h303, 12'h304, 12'h305,
      12'h340, 12'h341, 12'h342, 12'h343, 12'h344, 12'hF14,
      12'h100, 12'h104, 12'h105, 12'h140, 12'h141, 12'h142,
      12'h143, 12'h144, 12'h180: csr_exists = 1'b1;
      default:                    csr_exists = 1'b0;
    endcase
  end

  assign csr_illegal_o = csr_req_valid_i && (!csr_exists || priv_insufficient || write_to_ro);

  // --------------------------------------------------------------------------
  // CSR Read Logic (Combinational for EX stage old value)
  // --------------------------------------------------------------------------
  always @(*) begin
    case (csr_addr_i)
      // Machine-mode CSRs
      12'h300: csr_rdata_o = mstatus_q;
      12'h301: csr_rdata_o = 64'h80000000_0014112D; // RV64IMAFDCSU
      12'h302: csr_rdata_o = {{(XLEN-16){1'b0}}, medeleg_q};
      12'h303: csr_rdata_o = {{(XLEN-16){1'b0}}, mideleg_q};
      12'h304: csr_rdata_o = mie_wire;
      12'h305: csr_rdata_o = mtvec_q;
      12'h340: csr_rdata_o = mscratch_q;
      12'h341: csr_rdata_o = mepc_q;
      12'h342: csr_rdata_o = mcause_q;
      12'h343: csr_rdata_o = mtval_q;
      12'h344: csr_rdata_o = mip_wire;
      12'hF14: csr_rdata_o = {{(XLEN-2){1'b0}}, HART_ID[1:0]}; // mhartid

      // Supervisor-mode CSRs
      12'h100: csr_rdata_o = sstatus_wire;
      12'h104: csr_rdata_o = sie_wire;
      12'h105: csr_rdata_o = stvec_q;
      12'h140: csr_rdata_o = sscratch_q;
      12'h141: csr_rdata_o = sepc_q;
      12'h142: csr_rdata_o = scause_q;
      12'h143: csr_rdata_o = stval_q;
      12'h144: csr_rdata_o = sip_wire;
      12'h180: csr_rdata_o = satp_o;

      default: csr_rdata_o = {XLEN{1'b0}};
    endcase
  end

  // --------------------------------------------------------------------------
  // CSR Write Value Calculation (RW, RS, RC)
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] csr_next_val = (csr_op_i == 2'b01) ? csr_wdata_i :
                                 (csr_op_i == 2'b10) ? (csr_rdata_o | csr_wdata_i) :
                                 (csr_op_i == 2'b11) ? (csr_rdata_o & ~csr_wdata_i) :
                                 csr_wdata_i;

  // --------------------------------------------------------------------------
  // Delegation & Trap Destination Determination
  // --------------------------------------------------------------------------
  wire is_interrupt_trap = exception_cause_i[5]; // Bit 5 denotes interrupt
  wire [3:0] trap_code   = exception_cause_i[3:0];

  wire trap_to_s = (priv_mode_o < 2'b11) &&
                   (is_interrupt_trap ? mideleg_q[trap_code] : medeleg_q[trap_code]);

  assign trap_flush_o   = exception_valid_i || mret_valid_i || sret_valid_i ||
                          sfence_valid_i    || (csr_req_valid_i && csr_wen_i && (csr_addr_i == 12'h180));
  assign sfence_flush_o = sfence_valid_i;

  // --------------------------------------------------------------------------
  // Interrupt Evaluation & Prioritization
  // --------------------------------------------------------------------------
  wire m_int_enable = (priv_mode_o < 2'b11) || (priv_mode_o == 2'b11 && mstatus_q[3]); // mstatus.MIE
  wire s_int_enable = (priv_mode_o < 2'b01) || (priv_mode_o == 2'b01 && mstatus_q[1]); // mstatus.SIE

  wire [XLEN-1:0] m_pending_masked = mip_wire & mie_wire & ~{{(XLEN-16){1'b0}}, mideleg_q};
  wire [XLEN-1:0] s_pending_masked = mip_wire & mie_wire & {{(XLEN-16){1'b0}}, mideleg_q};

  wire has_m_interrupt = m_int_enable && (|m_pending_masked);
  wire has_s_interrupt = s_int_enable && (|s_pending_masked);

  assign interrupt_pending_o = (has_m_interrupt || has_s_interrupt) && !wfi_sleep_o;

  // Interrupt priority encoder
  assign interrupt_cause_o = has_m_interrupt ?
    (m_pending_masked[11] ? {1'b1, 5'd11} : // MEIP
     m_pending_masked[3]  ? {1'b1, 5'd3}  : // MSIP
     m_pending_masked[7]  ? {1'b1, 5'd7}  : // MTIP
     {1'b1, 5'd0}) :
    (s_pending_masked[9]  ? {1'b1, 5'd9}  : // SEIP
     s_pending_masked[1]  ? {1'b1, 5'd1}  : // SSIP
     s_pending_masked[5]  ? {1'b1, 5'd5}  : // STIP
     {1'b1, 5'd0});

  // --------------------------------------------------------------------------
  // State Machine & Register Updates
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      priv_mode_o      <= 2'b11; // Reset to Machine-mode
      mstatus_q        <= 64'h0000000a_00001800; // UXL=64, SXL=64, MPP=M
      medeleg_q        <= 16'd0;
      mideleg_q        <= 16'd0;
      mie_q            <= 12'd0;
      mtvec_q          <= 64'h00000000_80000004; // Standard boot trap handler
      mscratch_q       <= {XLEN{1'b0}};
      mepc_q           <= {XLEN{1'b0}};
      mcause_q         <= {XLEN{1'b0}};
      mtval_q          <= {XLEN{1'b0}};

      stvec_q          <= 64'h00000000_80000000;
      sscratch_q       <= {XLEN{1'b0}};
      sepc_q           <= {XLEN{1'b0}};
      scause_q         <= {XLEN{1'b0}};
      stval_q          <= {XLEN{1'b0}};
      satp_o           <= {XLEN{1'b0}};

      ssip_q           <= 1'b0;
      wfi_sleep_o      <= 1'b0;
      trap_target_pc_o <= {XLEN{1'b0}};
    end else begin
      // WFI sleep management
      if (wfi_valid_i) begin
        wfi_sleep_o <= 1'b1;
      end else if (| (mip_wire & mie_wire)) begin
        wfi_sleep_o <= 1'b0; // Wakeup on any pending & enabled interrupt
      end

      // 1. Trap / Exception / Interrupt Entry
      if (exception_valid_i) begin
        if (trap_to_s) begin
          // S-mode Trap
          sepc_q           <= exception_pc_i;
          scause_q         <= {is_interrupt_trap, {(XLEN-6){1'b0}}, exception_cause_i[4:0]};
          stval_q          <= exception_tval_i;
          mstatus_q[8]     <= priv_mode_o[0];    // SPP <= previous priv
          mstatus_q[5]     <= mstatus_q[1];      // SPIE <= SIE
          mstatus_q[1]     <= 1'b0;              // SIE <= 0
          priv_mode_o      <= 2'b01;             // To S-mode
          trap_target_pc_o <= (stvec_q[1:0] == 2'b01 && is_interrupt_trap) ?
                              ({stvec_q[XLEN-1:2], 2'b00} + (exception_cause_i[4:0] << 2)) :
                              {stvec_q[XLEN-1:2], 2'b00};
        end else begin
          // M-mode Trap
          mepc_q           <= exception_pc_i;
          mcause_q         <= {is_interrupt_trap, {(XLEN-6){1'b0}}, exception_cause_i[4:0]};
          mtval_q          <= exception_tval_i;
          mstatus_q[12:11] <= priv_mode_o;       // MPP <= previous priv
          mstatus_q[7]     <= mstatus_q[3];      // MPIE <= MIE
          mstatus_q[3]     <= 1'b0;              // MIE <= 0
          priv_mode_o      <= 2'b11;             // To M-mode
          trap_target_pc_o <= (mtvec_q[1:0] == 2'b01 && is_interrupt_trap) ?
                              ({mtvec_q[XLEN-1:2], 2'b00} + (exception_cause_i[4:0] << 2)) :
                              {mtvec_q[XLEN-1:2], 2'b00};
        end
      end
      // 2. MRET Return
      else if (mret_valid_i && (priv_mode_o == 2'b11)) begin
        priv_mode_o      <= mstatus_q[12:11]; // Restore priv from MPP
        mstatus_q[3]     <= mstatus_q[7];     // MIE <= MPIE
        mstatus_q[7]     <= 1'b1;             // MPIE <= 1
        mstatus_q[12:11] <= 2'b00;            // MPP <= U
        trap_target_pc_o <= mepc_q;
      end
      // 3. SRET Return
      else if (sret_valid_i && (priv_mode_o >= 2'b01) && !mstatus_q[22]) begin // TSR check
        priv_mode_o      <= {1'b0, mstatus_q[8]}; // Restore priv from SPP
        mstatus_q[1]     <= mstatus_q[5];         // SIE <= SPIE
        mstatus_q[5]     <= 1'b1;                 // SPIE <= 1
        mstatus_q[8]     <= 1'b0;                 // SPP <= U
        trap_target_pc_o <= sepc_q;
      end
      // 4. CSR Write / Update
      else if (csr_req_valid_i && csr_wen_i && !csr_illegal_o) begin
        case (csr_addr_i)
          12'h300: begin // mstatus
            mstatus_q[3]     <= csr_next_val[3];     // MIE
            mstatus_q[7]     <= csr_next_val[7];     // MPIE
            mstatus_q[8]     <= csr_next_val[8];     // SPP
            mstatus_q[12:11] <= csr_next_val[12:11]; // MPP
            mstatus_q[14:13] <= csr_next_val[14:13]; // FS
            mstatus_q[18]    <= csr_next_val[18];    // SUM
            mstatus_q[19]    <= csr_next_val[19];    // MXR
            mstatus_q[20]    <= csr_next_val[20];    // TVM
            mstatus_q[21]    <= csr_next_val[21];    // TW
            mstatus_q[22]    <= csr_next_val[22];    // TSR
          end
          12'h302: medeleg_q  <= csr_next_val[15:0];
          12'h303: mideleg_q  <= csr_next_val[15:0];
          12'h304: mie_q      <= csr_next_val[11:0];
          12'h305: mtvec_q    <= {csr_next_val[XLEN-1:2], csr_next_val[1:0]};
          12'h340: mscratch_q <= csr_next_val;
          12'h341: mepc_q     <= {csr_next_val[XLEN-1:2], 2'b00};
          12'h342: mcause_q   <= csr_next_val;
          12'h343: mtval_q    <= csr_next_val;
          12'h344: ssip_q     <= csr_next_val[1]; // S-software interrupt

          12'h100: begin // sstatus
            mstatus_q[1]     <= csr_next_val[1];  // SIE
            mstatus_q[5]     <= csr_next_val[5];  // SPIE
            mstatus_q[8]     <= csr_next_val[8];  // SPP
            mstatus_q[14:13] <= csr_next_val[14:13]; // FS
            mstatus_q[18]    <= csr_next_val[18]; // SUM
            mstatus_q[19]    <= csr_next_val[19]; // MXR
          end
          12'h104: mie_q      <= (mie_q & ~mideleg_q[11:0]) | (csr_next_val[11:0] & mideleg_q[11:0]);
          12'h105: stvec_q    <= {csr_next_val[XLEN-1:2], csr_next_val[1:0]};
          12'h140: sscratch_q <= csr_next_val;
          12'h141: sepc_q     <= {csr_next_val[XLEN-1:2], 2'b00};
          12'h142: scause_q   <= csr_next_val;
          12'h143: stval_q    <= csr_next_val;
          12'h144: ssip_q     <= csr_next_val[1];
          12'h180: satp_o     <= csr_next_val;

          default: ;
        endcase
      end
    end
  end

endmodule
