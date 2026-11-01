// pmu_props: formal properties for pmu_top (docs/BRIEF.md A3, docs/SPEC.md section 9).
// Bound into pmu_top (see the bind at the end). Immediate assertions with $past, as the brief asks.
// Internal signals are reached through hierarchical names (pmu_top.g_pd[d].u_pd...).
//
// Environment assumptions (each is a fact about the outside world, not about the PMU):
//   SW  power switch: an ack rises only while its enable was high, falls only while it was low.
//   QD  Q-Channel device, ARM IHI 0068D 2.1.2: device handshake rules, and both outputs LOW while
//       the device is in reset ("At reset assertion, a device must drive both QACCEPTn and QDENY
//       LOW").
//   R   PRESETn is asserted in the first cycle.
// yosys-slang supports $past but not $rose/$fell/$changed/$onehot0, so they are spelled out
// with $past (identical meaning for 1-bit signals).
`define ROSE(x)     ((x) && !$past(x))
`define FELL(x)     (!(x) && $past(x))
`define CHANGED(x)  ((x) != $past(x))
`define ONEHOT0(v)  ((((v) & ((v) - 1'b1))) == '0)

module pmu_props #(
    parameter int              N_PD    = 3,
    parameter logic [N_PD-1:0] HAS_RET = '0
) ();
    // ------------------------------------------------------------------ clock and reset
    logic clk;
    assign clk = pmu_top.PCLK;
    logic rstn;
    assign rstn = pmu_top.rstn;

    logic init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!pmu_top.PRESETn);                     // R

    logic past_ok = 1'b0;                     // $past is meaningful (not the first cycle)
    always @(posedge clk) past_ok <= 1'b1;

    for (genvar d = 0; d < N_PD; d++) begin : g_d
        // -------------------------------------------------------------- environment: switches (SW)
        always @(posedge clk) if (past_ok) begin
            if (`ROSE(pmu_top.psw_trickle_ack[d])) assume ($past(pmu_top.psw_trickle_en[d]));
            if (`FELL(pmu_top.psw_trickle_ack[d])) assume (!$past(pmu_top.psw_trickle_en[d]));
            if (`ROSE(pmu_top.psw_main_ack[d]))    assume ($past(pmu_top.psw_main_en[d]));
            if (`FELL(pmu_top.psw_main_ack[d]))    assume (!$past(pmu_top.psw_main_en[d]));
        end

        // -------------------------------------------------------------- environment: device (QD)
        logic qa, qd, qr, drst;
        assign qa   = pmu_top.QACCEPTn[d];
        assign qd   = pmu_top.QDENY[d];
        assign qr   = pmu_top.QREQn[d];
        assign drst = !pmu_top.rst_n[d];        // device in reset
        always @(*) if (drst) assume (!qa && !qd);
        always @(*) assume (!(!qa && qd));       // x01 is illegal (IHI 0068D Table 2-1)
        // Applied in every cycle the device is out of reset, including the cycle it leaves reset:
        // it leaves reset in Q_STOPPED and may only move by the rules (cex02).
        always @(posedge clk) if (past_ok && !drst) begin
            if (`FELL(qa)) assume ($past(!qr && !qd));    // QACCEPTn falls: QREQn=0, QDENY=0
            if (`ROSE(qa)) assume ($past( qr && !qd));    // QACCEPTn rises: QREQn=1, QDENY=0
            if (`ROSE(qd)) assume ($past(!qr &&  qa));    // QDENY rises:    QREQn=0, QACCEPTn=1
            if (`FELL(qd)) assume ($past( qr &&  qa));    // QDENY falls:    QREQn=1, QACCEPTn=1
        end

        // -------------------------------------------------------------- the domain's signals
        logic pwr_good, iso, cke, rn, sav, trk_en, main_en;
        assign pwr_good = pmu_top.trk_s[d] && pmu_top.main_s[d];      // synchronised acks (SPEC 2.3)
        assign iso      = pmu_top.iso_en[d];
        assign cke      = pmu_top.clk_en[d];
        assign rn       = pmu_top.rst_n[d];
        assign sav      = pmu_top.ret_save[d];
        assign trk_en   = pmu_top.psw_trickle_en[d];
        assign main_en  = pmu_top.psw_main_en[d];

        // P1: no power -> isolated, clock stopped, in reset
        always @(*) if (!pwr_good) p1: assert (iso && !cke && !rn);

        // P2: isolation released only when powered and out of reset, and released last
        always @(*) if (!iso) p2a: assert (pwr_good && rn);
        always @(posedge clk) if (past_ok && `FELL(iso)) p2b: assert (cke);

        // P3: retention save only while isolated with the clock stopped
        always @(*) if (sav) p3: assert (iso && !cke);

        // P4: main switch only after the trickle ack has been high for DLY_TRICKLE cycles
        logic [16:0] trk_hi = '0;               // consecutive cycles psw_trickle_ack (pin) is high
        always @(posedge clk) begin
            if (!pmu_top.psw_trickle_ack[d]) trk_hi <= '0;
            else if (trk_hi != 17'h1ffff)    trk_hi <= trk_hi + 17'd1;
        end
        logic [16:0] dly_tr;
        assign dly_tr = (pmu_top.dly_trickle == 16'd0) ? 17'd1 : {1'b0, pmu_top.dly_trickle};
        always @(posedge clk) if (past_ok && `ROSE(main_en) && $past(rstn))
            p4: assert ({1'b0, $past(trk_hi)} + 18'd1 >= {1'b0, $past(dly_tr)});   // 18 bits: no wrap
        // Helper invariant for induction (itself proven): while the trickle switch is being
        // turned on, the PMU's count of synchronised ack-high cycles never exceeds the time the
        // real ack pin has been high. A synchronised high is a pin high from SYNC_STAGES cycles
        // earlier, and the pin cannot fall while the enable is high (assumption SW).
        always @(*) if (pmu_top.g_pd[d].u_pd.st == 5'd14) begin       // U_TRK_ON
            h4a: assert (trk_en);
            h4b: assert ({1'b0, pmu_top.g_pd[d].u_pd.hcnt} <= trk_hi);
        end

        // P6: Q-Channel controller rules (IHI 0068D 2.1.2, p. 2-23) on the real pins
        always @(posedge clk) if (past_ok && $past(rstn) && rstn) begin
            if (`FELL(qr)) p6a: assert ($past(qa && !qd));          // fall only from Q_RUN
            if (`ROSE(qr)) p6b: assert ($past(qa == qd));           // rise only from 00 or 11
        end
        // Device reset only in Q_STOPPED (IHI 0068D 2.1.2, "Device reset")
        always @(posedge clk) if (past_ok && $past(rstn) && rstn && `FELL(rn))
            p6c: assert ($past(!qr && !qa && !qd));

        // Helper invariants for induction (each is itself proven).
        // States (MICROARCH): 0 ON 1 CG 2 RET 3 OFF 4 FAULT 5 D_QWAIT 6 D_DENY 7 D_CLK 8 D_ISO
        // 9 D_SAVE 10 D_RST 11 D_MAIN_OFF 12 D_TRK_OFF 13 U_ARB 14 U_TRK_ON 15 U_MAIN_ON
        // 16 U_RESTORE 17 U_RST 18 U_CLK 19 U_ISO 20 U_QEXIT 21 C_CLK
        logic [4:0] st;
        logic       fq;
        logic [4:0] rs;
        assign st = pmu_top.g_pd[d].u_pd.st;
        assign fq = pmu_top.g_pd[d].u_pd.fault_q;
        assign rs = pmu_top.g_pd[d].u_pd.resume_st;
        // the domain is powered: from the end of U_MAIN_ON to the start of D_MAIN_OFF, or in a
        // Q-Channel fault (which holds the outputs of a powered wait state)
        logic pwrd;
        assign pwrd = (st inside {5'd0, 5'd1, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10,
                                  5'd16, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21}) || (st == 5'd4 && fq);
        always @(*) if (pwrd) begin
            h1a: assert (trk_en && main_en);
            h1b: assert (pmu_top.psw_trickle_ack[d] && pmu_top.psw_main_ack[d]);
            h1c: assert (&pmu_top.g_pd[d].u_s_trk.s && &pmu_top.g_pd[d].u_s_main.s);
        end
        always @(*) if (st == 5'd4 && fq) h1d: assert (rs inside {5'd5, 5'd6, 5'd20});
        // trickle switch firmly on while the main switch turns on (U_MAIN_ON) or off (D_MAIN_OFF)
        always @(*) if (st inside {5'd11, 5'd15}) begin
            h1e: assert (pmu_top.psw_trickle_ack[d]);
            h1f: assert (&pmu_top.g_pd[d].u_s_trk.s);
        end
        // the output table: the state that sets each output (MICROARCH "pd_ctrl states")
        logic [4:0] so;                         // state whose outputs apply (resume state in a Q fault)
        assign so = (st == 5'd4 && fq) ? rs : st;
        always @(*) begin
            if (so inside {5'd0, 5'd1, 5'd5, 5'd6, 5'd7, 5'd19, 5'd20, 5'd21})       h2a: assert (!iso);
            else                                                                      h2b: assert (iso);
            if (so inside {5'd0, 5'd1, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21})
                                                                                      h2c: assert (rn);
            else                                                                      h2d: assert (!rn);
            if (so inside {5'd0, 5'd5, 5'd6, 5'd18, 5'd19, 5'd20, 5'd21})            h2e: assert (cke);
            else                                                                      h2f: assert (!cke);
        end

        // Q-Channel in Q_STOPPED from the accept onwards and in every off state: QREQn low, the
        // device pins low, the synchroniser stages low, no request pending.
        always @(*) if (so inside {5'd1, 5'd2, 5'd3, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11, 5'd12,
                                   5'd13, 5'd14, 5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd21}
                        || (st == 5'd4 && !fq)) begin
            h3a: assert (!qr && !qa && !qd);
            h3b: assert (pmu_top.g_pd[d].u_s_acc.s == '0 && pmu_top.g_pd[d].u_s_deny.s == '0);
            h3c: assert (!pmu_top.stop_req[d]);
        end

        // ret_save only in D_SAVE, ret_restore only in U_RESTORE; no retention states without HAS_RET
        always @(*) begin
            h4c: assert (sav == (st == 5'd9));
            h4d: assert (pmu_top.ret_restore[d] == (st == 5'd16));
            if (!HAS_RET[d]) h4e: assert (!(st inside {5'd2, 5'd9, 5'd16}) && !pmu_top.g_pd[d].u_pd.ret_valid);
        end

        // the Q-Channel requests to qch_master are exactly the two wait states that need them
        always @(*) begin
            h5a: assert (pmu_top.exit_req[d] == (so == 5'd20));
            h5b: assert (pmu_top.stop_req[d] == (so == 5'd5));
        end

        // switch enables per state: trickle on from U_TRK_ON to D_MAIN_OFF, main from U_MAIN_ON to D_RST
        always @(*) begin
            h6a: assert (trk_en  == (so inside {5'd0, 5'd1, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11,
                                                5'd14, 5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21}));
            h6b: assert (main_en == (so inside {5'd0, 5'd1, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10,
                                                5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21}));
        end

        // inrush: requesting exactly in U_ARB..U_MAIN_ON; in the switching phase the grant is held
        always @(*) begin
            h7a: assert (pmu_top.inrush_req[d] == (st inside {5'd13, 5'd14, 5'd15}));
            if (st inside {5'd14, 5'd15}) h7b: assert (pmu_top.inrush_gnt[d]);
        end

        // P8: the domain FSM stays in its 22 legal states
        always @(*) p8a: assert (pmu_top.g_pd[d].u_pd.st <= 5'd21);

        // ---------------------------------------------------------------- covers
        always @(*) begin
            c_on:    cover (pmu_top.g_pd[d].u_pd.st == 5'd0);
            c_cg:    cover (pmu_top.g_pd[d].u_pd.st == 5'd1);
            c_off:   cover (pmu_top.g_pd[d].u_pd.st == 5'd3);
            c_fault: cover (pmu_top.g_pd[d].u_pd.st == 5'd4);
            c_deny:  cover (pmu_top.g_pd[d].u_pd.ev_deny);
        end
        if (HAS_RET[d]) begin : g_ret
            always @(*) c_ret: cover (pmu_top.g_pd[d].u_pd.st == 5'd2);
        end
    end

    // P5: inrush - at most one domain in its power-up switching phase
    always @(*) p5: assert (`ONEHOT0(pmu_top.in_pu_switch));

    // P8: arbiter grant is one-hot or zero
    always @(*) p8b: assert (`ONEHOT0(pmu_top.u_arb.gnt));

    // P7: APB - PREADY and PSLVERR only in the access phase (IHI 0024E 3.4, 4.1)
    logic access;
    assign access = pmu_top.PSEL && pmu_top.PENABLE;
    always @(*) begin
        p7a: assert (pmu_top.PREADY == access);
        if (pmu_top.PSLVERR) p7b: assert (access && pmu_top.PREADY);
    end
    // P7: configuration registers change only on a valid write to their own address.
    // "Valid write" is computed here from the APB pins and the register map, independently of the
    // design's own decode (a mutation using the design's `we` went unnoticed: DECISIONS F-005).
    logic [11:0] wa;
    assign wa = {pmu_top.PADDR[11:2], 2'b00};
    logic wr_ok;
    assign wr_ok = pmu_top.PSEL && pmu_top.PENABLE && pmu_top.PWRITE &&
                   !((wa == pmu_regmap_pkg::ADDR_MODE_REQ || wa == pmu_regmap_pkg::ADDR_WAKE_MODE) &&
                     pmu_top.PWDATA[2:0] > 3'd4);
    `define P7_REG(reg, addr) \
        always @(posedge clk) if (past_ok && $past(rstn) && rstn && `CHANGED(pmu_top.u_regs.reg)) \
            p7_``reg: assert ($past(wr_ok && wa == pmu_regmap_pkg::addr));
    `P7_REG(dly_trickle, ADDR_DLY_TRICKLE)
    `P7_REG(dly_main,    ADDR_DLY_MAIN)
    `P7_REG(dly_clk,     ADDR_DLY_CLK)
    `P7_REG(dly_iso,     ADDR_DLY_ISO)
    `P7_REG(dly_ret,     ADDR_DLY_RET)
    `P7_REG(dly_rst,     ADDR_DLY_RST)
    `P7_REG(tmo_qch,     ADDR_TMO_QCH)
    `P7_REG(tmo_psw,     ADDR_TMO_PSW)
    `P7_REG(wake_mask,   ADDR_WAKE_MASK)
    `P7_REG(timer_cmp,   ADDR_WAKE_TIMER_CMP)
    `P7_REG(irq_en,      ADDR_IRQ_EN)
    `P7_REG(wake_mode,   ADDR_WAKE_MODE)
    `undef P7_REG

`ifdef LIVE
    // ------------------------------------------------------------------ P9: bounded liveness
    // Task "live" only. Restriction (stated in docs/VERIFICATION.md): the DLY_*/TMO_* registers
    // are not written, so they keep their reset values (DLY_TRICKLE 8, DLY_MAIN 4, the other
    // DLY_* 2, TMO_* 256). The end-to-end bound is the sum of the per-state bounds along the
    // longest path of the transition graph (docs/VERIFICATION.md); here each piece is proven.
    always @(*) if (pmu_top.u_regs.we && (pmu_top.u_regs.a inside {
            pmu_regmap_pkg::ADDR_DLY_TRICKLE, pmu_regmap_pkg::ADDR_DLY_MAIN, pmu_regmap_pkg::ADDR_DLY_CLK,
            pmu_regmap_pkg::ADDR_DLY_ISO, pmu_regmap_pkg::ADDR_DLY_RET, pmu_regmap_pkg::ADDR_DLY_RST,
            pmu_regmap_pkg::ADDR_TMO_QCH, pmu_regmap_pkg::ADDR_TMO_PSW}))
        assume (1'b0);

    // helper: with no writes, the configuration stays at its reset values (proven)
    always @(*) if (rstn) begin
        h9c: assert (pmu_top.u_regs.dly_trickle == pmu_regmap_pkg::RST_DLY_TRICKLE[15:0] &&
                     pmu_top.u_regs.dly_main    == pmu_regmap_pkg::RST_DLY_MAIN[15:0] &&
                     pmu_top.u_regs.dly_clk     == pmu_regmap_pkg::RST_DLY_CLK[15:0] &&
                     pmu_top.u_regs.dly_iso     == pmu_regmap_pkg::RST_DLY_ISO[15:0] &&
                     pmu_top.u_regs.dly_ret     == pmu_regmap_pkg::RST_DLY_RET[15:0] &&
                     pmu_top.u_regs.dly_rst     == pmu_regmap_pkg::RST_DLY_RST[15:0] &&
                     pmu_top.u_regs.tmo_qch     == pmu_regmap_pkg::RST_TMO_QCH[15:0] &&
                     pmu_top.u_regs.tmo_psw     == pmu_regmap_pkg::RST_TMO_PSW[15:0]);
    end

    for (genvar d = 0; d < N_PD; d++) begin : g_live
        logic [4:0]  st;
        logic [16:0] cnt;
        logic [15:0] tis, tis_r;                // cycles spent in the current state (1 = first)
        logic [4:0]  st_q;
        assign st  = pmu_top.g_pd[d].u_pd.st;
        assign cnt = pmu_top.g_pd[d].u_pd.cnt;
        always @(posedge clk) begin
            st_q  <= st;
            tis_r <= tis;
        end
        assign tis = (!past_ok || st != st_q) ? 16'd1 : (tis_r == 16'hffff ? tis_r : tis_r + 16'd1);
        // per-state bound on the time spent there (cycles), from SPEC 4 and the reset config
        always @(*) if (past_ok && rstn) begin
            if (st inside {5'd7, 5'd8, 5'd9, 5'd10, 5'd16, 5'd17, 5'd18, 5'd21})
                p9a_hold: assert (tis <= 16'd2);              // DLY_CLK/ISO/RET/RST = 2
            if (st == 5'd19)
                p9a_iso:  assert (tis <= 16'd1);              // U_ISO: one cycle
            if (st inside {5'd5, 5'd6, 5'd20, 5'd11, 5'd12})
                p9a_wait: assert (tis <= 16'd256);            // TMO_QCH / TMO_PSW = 256
            if (st == 5'd14)
                p9a_trk:  assert (tis <= 16'd264);            // TMO_PSW + DLY_TRICKLE
            if (st == 5'd15)
                p9a_main: assert (tis <= 16'd260);            // TMO_PSW + DLY_MAIN
        end
        // helper: in a bounded transient state the design's step counter equals the time in state
        // minus one (each such state is entered with cnt cleared)
        always @(*) if (past_ok && rstn && !(st inside {5'd0, 5'd1, 5'd2, 5'd3, 5'd4, 5'd13, 5'd19}))
            h9a: assert ({1'b0, tis} == cnt + 17'd1);
        // a stable state that is armed and not at its target is left in the next cycle
        logic leave;
        assign leave = pmu_top.armed[d] && !pmu_top.at_tgt[d] && (st inside {5'd0, 5'd1, 5'd2, 5'd3});
        always @(posedge clk) if (past_ok && $past(rstn) && rstn && $past(leave))
            p9b: assert (st != $past(st));
    end
    // arbiter progress: when no grant is held, the lowest-index requester is granted next cycle
    always @(posedge clk) if (past_ok && $past(rstn) && rstn && $past(pmu_top.u_arb.gnt) == '0
                              && $past(pmu_top.inrush_req) != '0)
        p9c: assert (pmu_top.u_arb.gnt == ($past(pmu_top.inrush_req) & -$past(pmu_top.inrush_req)));
`endif

    // ------------------------------------------------------------------ system covers
    // a full RUN -> SHUTDOWN -> RUN cycle, seen on MODE_STATUS.MODE
    logic seen_run, seen_sd;
    always @(posedge clk) begin
        if (!rstn) begin seen_run <= 1'b0; seen_sd <= 1'b0; end
        else begin
            if (pmu_top.mode_cur == pmu_regmap_pkg::MODE_RUN && !seen_sd)     seen_run <= 1'b1;
            if (pmu_top.mode_cur == pmu_regmap_pkg::MODE_SHUTDOWN && seen_run) seen_sd <= 1'b1;
        end
    end
    always @(*) c_run_sd_run: cover (seen_sd && pmu_top.mode_cur == pmu_regmap_pkg::MODE_RUN);
endmodule

`undef ROSE
`undef FELL
`undef CHANGED
`undef ONEHOT0

bind pmu_top pmu_props #(.N_PD(N_PD), .HAS_RET(HAS_RET)) u_props ();
