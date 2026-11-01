// pmu_top: multi-domain power-management unit (docs/SPEC.md, docs/BRIEF.md A2).
// Lives in the always-on domain. Controls N_PD switchable domains; domain d has retention when
// HAS_RET[d] = 1. Default: PD_CPU (0, retention), PD_DSP (1, retention), PD_PERI (2, none).
//
// Per domain: Q-Channel inputs pass through isolation cells (clamp 0, SPEC 2.2) and then a
// synchroniser; power-switch acks and wake_irq are synchronised; pd_ctrl sequences the outputs;
// an ICG (icg_wrap) gates the domain clock pd_clk[d] from PCLK with clk_en[d].
module pmu_top #(
    parameter int              N_PD        = 3,
    parameter logic [N_PD-1:0] HAS_RET     = 3'b011,
    parameter int              SYNC_STAGES = 2
) (
    // APB3 (ARM IHI 0024E)
    input  logic              PCLK,
    input  logic              PRESETn,
    input  logic              PSEL,
    input  logic              PENABLE,
    input  logic              PWRITE,
    input  logic [11:0]       PADDR,
    input  logic [31:0]       PWDATA,
    output logic [31:0]       PRDATA,
    output logic              PREADY,
    output logic              PSLVERR,
    // Q-Channel, one per domain (ARM IHI 0068D)
    output logic [N_PD-1:0]   QREQn,
    input  logic [N_PD-1:0]   QACCEPTn,
    input  logic [N_PD-1:0]   QDENY,
    input  logic [N_PD-1:0]   QACTIVE,
    // power control, one bit per domain
    output logic [N_PD-1:0]   clk_en,
    output logic [N_PD-1:0]   pd_clk,
    output logic [N_PD-1:0]   iso_en,
    output logic [N_PD-1:0]   ret_save,
    output logic [N_PD-1:0]   ret_restore,
    output logic [N_PD-1:0]   rst_n,
    output logic [N_PD-1:0]   psw_trickle_en,
    output logic [N_PD-1:0]   psw_main_en,
    input  logic [N_PD-1:0]   psw_trickle_ack,
    input  logic [N_PD-1:0]   psw_main_ack,
    // wake-up, interrupt, debug
    input  logic [7:0]        wake_irq,
    output logic              irq,
    output logic [7*N_PD:0]   pmu_state
);
    import pmu_regmap_pkg::*;

    logic rstn;
    rst_sync u_rst (.clk(PCLK), .rst_n_in(PRESETn), .rst_n(rstn));

    // ---------------------------------------------------------------- registers
    logic [2:0]  mode_req;
    logic        arm, timer_en, timer_start, timer_fire, wake_evt, fault_clr;
    logic [7:0]  wake_mask;
    logic [31:0] timer_cmp, timer_cnt, mode_status, pd_state_reg;
    logic [15:0] dly_trickle, dly_main, dly_clk, dly_iso, dly_ret, dly_rst, tmo_qch, tmo_psw;
    logic        ev_done, ev_deny_any;
    logic [N_PD-1:0]   ev_deny, ev_fault;
    logic [N_PD*3-1:0] fault_step_vec;

    apb_regs #(.N_PD(N_PD)) u_regs (
        .clk(PCLK), .rst_n(rstn),
        .psel(PSEL), .penable(PENABLE), .pwrite(PWRITE), .paddr(PADDR), .pwdata(PWDATA),
        .prdata(PRDATA), .pready(PREADY), .pslverr(PSLVERR),
        .mode_req(mode_req), .arm(arm), .wake_mask(wake_mask),
        .timer_cmp(timer_cmp), .timer_en(timer_en), .timer_start(timer_start),
        .dly_trickle(dly_trickle), .dly_main(dly_main), .dly_clk(dly_clk), .dly_iso(dly_iso),
        .dly_ret(dly_ret), .dly_rst(dly_rst), .tmo_qch(tmo_qch), .tmo_psw(tmo_psw),
        .fault_clr(fault_clr), .irq(irq),
        .mode_status(mode_status), .pd_state_reg(pd_state_reg), .timer_cnt(timer_cnt),
        .timer_fire(timer_fire), .wake_evt(wake_evt), .ev_done(ev_done), .ev_deny(ev_deny_any),
        .ev_fault(ev_fault), .fault_step_vec(fault_step_vec));

    // ---------------------------------------------------------------- wake-up
    logic [7:0] wake_irq_s;
    for (genvar i = 0; i < 8; i++) begin : g_wsync
        sync_ff #(.STAGES(SYNC_STAGES)) u_s (.clk(PCLK), .rst_n(rstn), .d(wake_irq[i]), .q(wake_irq_s[i]));
    end
    wake_ctrl u_wake (
        .clk(PCLK), .rst_n(rstn), .wake_irq_s(wake_irq_s), .wake_mask(wake_mask),
        .timer_en(timer_en), .timer_start(timer_start), .timer_cmp(timer_cmp),
        .timer_cnt(timer_cnt), .timer_fire(timer_fire), .wake_evt(wake_evt));

    // ---------------------------------------------------------------- mode table (SPEC 3.2)
    // Per-domain target: 0 ON, 1 CLK_GATED, 2 RET, 3 OFF. Domain 0 = CPU, 1 = DSP, 2+ = PERI.
    function automatic logic [1:0] target(input logic [2:0] mode, input int d);
        logic [1:0] cpu, dsp, peri;
        unique case (mode)
            MODE_RUN:        begin cpu = 2'd0; dsp = 2'd0; peri = 2'd0; end
            MODE_IDLE:       begin cpu = 2'd1; dsp = 2'd1; peri = 2'd0; end
            MODE_SLEEP:      begin cpu = 2'd2; dsp = 2'd2; peri = 2'd1; end
            MODE_DEEP_SLEEP: begin cpu = 2'd2; dsp = 2'd3; peri = 2'd3; end
            default:         begin cpu = 2'd3; dsp = 2'd3; peri = 2'd3; end   // SHUTDOWN
        endcase
        return (d == 0) ? cpu : (d == 1) ? dsp : peri;
    endfunction

    // ---------------------------------------------------------------- domains
    logic [N_PD-1:0] inrush_req, inrush_gnt, busy, at_tgt, armed, ret_valid;
    // Power-up switching phase per domain: observed by the formal inrush property (property 5),
    // not used by the logic itself.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [N_PD-1:0] in_pu_switch;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [N_PD-1:0] stop_req, exit_req, q_run, q_stopped;
    logic [N_PD-1:0] qacc_iso, qdeny_iso, qact_iso, qacc_s, qdeny_s, qact_s, trk_s, main_s;
    logic [4:0]      st [N_PD];
    logic [2:0]      pd_state [N_PD];

    inrush_arb #(.N(N_PD)) u_arb (.clk(PCLK), .rst_n(rstn), .req(inrush_req), .gnt(inrush_gnt));

    // Per-domain targets, computed in a loop rather than by calling target() with the genvar in
    // a port connection: Icarus then stops treating the genvar as a constant (DECISIONS D-012).
    logic [1:0] tgt [N_PD];
    always_comb begin
        for (int i = 0; i < N_PD; i++) tgt[i] = target(mode_req, i);
    end

    for (genvar d = 0; d < N_PD; d++) begin : g_pd
        // isolation on every signal coming out of the switchable domain (clamp 0: Q_STOPPED)
        iso_wrap #(.CLAMP(1'b0)) u_iso_acc  (.d(QACCEPTn[d]), .iso_en(iso_en[d]), .q(qacc_iso[d]));
        iso_wrap #(.CLAMP(1'b0)) u_iso_deny (.d(QDENY[d]),    .iso_en(iso_en[d]), .q(qdeny_iso[d]));
        iso_wrap #(.CLAMP(1'b0)) u_iso_act  (.d(QACTIVE[d]),  .iso_en(iso_en[d]), .q(qact_iso[d]));

        sync_ff #(.STAGES(SYNC_STAGES)) u_s_acc  (.clk(PCLK), .rst_n(rstn), .d(qacc_iso[d]),        .q(qacc_s[d]));
        sync_ff #(.STAGES(SYNC_STAGES)) u_s_deny (.clk(PCLK), .rst_n(rstn), .d(qdeny_iso[d]),       .q(qdeny_s[d]));
        sync_ff #(.STAGES(SYNC_STAGES)) u_s_act  (.clk(PCLK), .rst_n(rstn), .d(qact_iso[d]),        .q(qact_s[d]));
        sync_ff #(.STAGES(SYNC_STAGES)) u_s_trk  (.clk(PCLK), .rst_n(rstn), .d(psw_trickle_ack[d]), .q(trk_s[d]));
        sync_ff #(.STAGES(SYNC_STAGES)) u_s_main (.clk(PCLK), .rst_n(rstn), .d(psw_main_ack[d]),    .q(main_s[d]));

        qch_master u_qch (
            .clk(PCLK), .rst_n(rstn), .stop_req(stop_req[d]), .exit_req(exit_req[d]),
            .qacceptn(qacc_s[d]), .qdeny(qdeny_s[d]), .qreqn(QREQn[d]),
            .q_run(q_run[d]), .q_stopped(q_stopped[d]));

        pd_ctrl #(.HAS_RET(HAS_RET[d]), .SYNC_STAGES(SYNC_STAGES)) u_pd (
            .clk(PCLK), .rst_n(rstn), .tgt(tgt[d]), .arm(arm), .fault_clr(fault_clr),
            .dly_trickle(dly_trickle), .dly_main(dly_main), .dly_clk(dly_clk), .dly_iso(dly_iso),
            .dly_ret(dly_ret), .dly_rst(dly_rst), .tmo_qch(tmo_qch), .tmo_psw(tmo_psw),
            .trickle_ack(trk_s[d]), .main_ack(main_s[d]),
            .q_run(q_run[d]), .q_stopped(q_stopped[d]), .q_deny(qdeny_s[d]),
            .stop_req(stop_req[d]), .exit_req(exit_req[d]),
            .inrush_req(inrush_req[d]), .inrush_gnt(inrush_gnt[d]),
            .clk_en(clk_en[d]), .iso_en(iso_en[d]), .ret_save(ret_save[d]),
            .ret_restore(ret_restore[d]), .rst_n_o(rst_n[d]),
            .psw_trickle_en(psw_trickle_en[d]), .psw_main_en(psw_main_en[d]),
            .st_o(st[d]), .pd_state(pd_state[d]), .busy(busy[d]), .at_tgt(at_tgt[d]),
            .armed(armed[d]), .ret_valid(ret_valid[d]), .in_pu_switch(in_pu_switch[d]),
            .ev_deny(ev_deny[d]), .ev_fault(ev_fault[d]), .fault_step(fault_step_vec[d*3 +: 3]));

        icg_wrap u_icg (.clk(PCLK), .en(clk_en[d]), .gclk(pd_clk[d]));
    end

    // ---------------------------------------------------------------- system status (SPEC 6)
    logic [2:0] mode_cur;
    logic       done_pending, all_at_tgt, sys_busy, sys_fault, mismatch;
    logic [N_PD-1:0] in_fault;
    for (genvar d = 0; d < N_PD; d++) begin : g_flt
        assign in_fault[d] = (pd_state[d] == PD_STATE_FAULT);
    end
    assign all_at_tgt  = &at_tgt;
    assign sys_busy    = |(armed & ~at_tgt);
    assign sys_fault   = |in_fault;
    assign mismatch    = !sys_busy && !all_at_tgt;
    assign ev_deny_any = |ev_deny;

    always_ff @(posedge PCLK or negedge rstn) begin
        if (!rstn) begin
            mode_cur     <= MODE_SHUTDOWN;
            done_pending <= 1'b1;            // boot request (MODE_REQ resets to RUN)
            ev_done      <= 1'b0;
        end else begin
            ev_done <= 1'b0;
            if (all_at_tgt) mode_cur <= mode_req;
            if (arm)                              done_pending <= 1'b1;
            else if (done_pending && all_at_tgt) begin
                done_pending <= 1'b0;
                ev_done      <= 1'b1;
            end
        end
    end

    assign mode_status = {21'd0, mismatch, sys_fault, sys_busy, 5'd0, mode_cur};
    always_comb begin
        pd_state_reg = '0;
        for (int d = 0; d < N_PD; d++) begin
            if (d < 4) pd_state_reg[8*d +: 5] = {ret_valid[d], busy[d], pd_state[d]};   // 4 fit in 32 bits
        end
    end

    // debug bus: {busy, per domain d at [7d+6:7d] {QACTIVE (synchronised), inrush grant, FSM state}}.
    // QACTIVE is observed only: the PMU is software-led (DECISIONS D-003.7).
    always_comb begin
        pmu_state[7*N_PD] = sys_busy;
        for (int d = 0; d < N_PD; d++) pmu_state[7*d +: 7] = {qact_s[d], inrush_gnt[d], st[d]};
    end
endmodule
