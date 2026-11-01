// pd_ctrl: power sequencer for one switchable domain (docs/SPEC.md sections 3-6).
// Instantiated N_PD times by pmu_top. All outputs are registered.
//
// Stable states: ON, CLK_GATED (CG), RET, OFF, FAULT. Every other state is one step of a
// sequence in SPEC section 4; a sequence always runs to the stable state it started towards
// (SPEC section 6, DECISIONS D-003.1), except for a deny (back to ON) or a FAULT.
module pd_ctrl #(
    parameter bit HAS_RET = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    // target for this domain from MODE_REQ (0 ON, 1 CLK_GATED, 2 RET, 3 OFF)
    input  logic [1:0]  tgt,
    input  logic        arm,            // pulse: new MODE_REQ (software write or wake event)
    input  logic        fault_clr,      // pulse: IRQ_STATUS.FAULT written 1
    // configuration (registers, SPEC section 4); 0 means 1 for delays, 65536 for timeouts
    input  logic [15:0] dly_trickle, dly_main, dly_clk, dly_iso, dly_ret, dly_rst,
    input  logic [15:0] tmo_qch, tmo_psw,
    // synchronised inputs
    input  logic        trickle_ack, main_ack,
    input  logic        q_run,          // Q_RUN observed (QREQn=1, QACCEPTn=1, QDENY=0)
    input  logic        q_stopped,      // Q_STOPPED observed (QREQn=0, QACCEPTn=0, QDENY=0)
    input  logic        q_deny,         // synchronised QDENY
    output logic        stop_req,       // to qch_master: drive QREQn low
    output logic        exit_req,       // to qch_master: drive QREQn high from Q_STOPPED
    // inrush arbiter
    output logic        inrush_req,
    input  logic        inrush_gnt,
    // domain controls
    output logic        clk_en, iso_en, ret_save, ret_restore, rst_n_o,
    output logic        psw_trickle_en, psw_main_en,
    // status and events
    output logic [4:0]  st_o,           // raw FSM state (debug bus)
    output logic [2:0]  pd_state,       // PD_STATE field: last stable state, or FAULT (7)
    output logic        busy,           // in a sequence
    output logic        at_tgt,         // stable and the target is satisfied (SPEC 3.2)
    output logic        armed,
    output logic        ret_valid,
    output logic        in_pu_switch,   // in the power-up switching phase (SPEC 4.4, property 5)
    output logic        ev_deny,        // pulse
    output logic        ev_fault,       // pulse
    output logic [2:0]  fault_step      // FAULT_INFO.STEP of the last fault
);
    import pmu_regmap_pkg::*;

    localparam logic [1:0] T_ON = 2'd0, T_CG = 2'd1, T_RET = 2'd2, T_OFF = 2'd3;

    // Binary-encoded states (DECISIONS: FSM encoding).
    typedef enum logic [4:0] {
        S_ON        = 5'd0,
        S_CG        = 5'd1,
        S_RET       = 5'd2,
        S_OFF       = 5'd3,
        S_FAULT     = 5'd4,
        D_QWAIT     = 5'd5,   // 4.1 steps 1-2: QREQn low, wait accept or deny
        D_DENY      = 5'd6,   // 4.5: QREQn high again, wait QDENY low (Q_RUN)
        D_CLK       = 5'd7,   // 4.1 step 3
        D_ISO       = 5'd8,   // step 4
        D_SAVE      = 5'd9,   // step 5
        D_RST       = 5'd10,  // step 6
        D_MAIN_OFF  = 5'd11,  // step 7a
        D_TRK_OFF   = 5'd12,  // step 7b / 8
        U_ARB       = 5'd13,  // 4.3 step 0
        U_TRK_ON    = 5'd14,  // steps 1-2
        U_MAIN_ON   = 5'd15,  // steps 3-4
        U_RESTORE   = 5'd16,  // step 5
        U_RST       = 5'd17,  // step 6
        U_CLK       = 5'd18,  // step 7
        U_ISO       = 5'd19,  // step 8
        U_QEXIT     = 5'd20,  // step 9
        C_CLK       = 5'd21   // 4.2 CG-up: clock on, then Q exit
    } st_t;

    st_t        st;
    logic [1:0] seq_tgt;        // target the current sequence runs to
    logic [16:0] cnt;           // cycles in this step (delay or timeout)
    logic [15:0] hcnt;          // consecutive cycles an ack has been high (steps with a hold)
    logic       fault_q;        // 1: Q-Channel timeout (outputs held), 0: power-switch timeout
    st_t        resume_st;      // wait state to resume after a Q-Channel fault is cleared
    logic [2:0] last_stable;
    logic       inrush_req_q;   // held from U_ARB to the end of U_MAIN_ON (SPEC 4.4)
    assign inrush_req = inrush_req_q;

    // target, with RET mapped to OFF for a domain without retention
    logic [1:0] t;
    assign t = (!HAS_RET && tgt == T_RET) ? T_OFF : tgt;

    function automatic logic [16:0] dly(input logic [15:0] v);
        return (v == 16'd0) ? 17'd1 : {1'b0, v};
    endfunction
    function automatic logic [16:0] tmo(input logic [15:0] v);
        return (v == 16'd0) ? 17'h10000 : {1'b0, v};
    endfunction

    logic [16:0] cnt1;
    assign cnt1 = cnt + 17'd1;

    // the delay of the current hold step
    logic [16:0] cur_dly;
    always_comb begin
        unique case (st)
            D_CLK, C_CLK, U_CLK: cur_dly = dly(dly_clk);
            D_ISO:               cur_dly = dly(dly_iso);
            D_SAVE, U_RESTORE:   cur_dly = dly(dly_ret);
            D_RST, U_RST:        cur_dly = dly(dly_rst);
            default:             cur_dly = 17'd1;
        endcase
    end
    logic hold_done;
    assign hold_done = (cnt1 >= cur_dly);

    // Timeouts (SPEC 4.6): a wait step whose acknowledge has not arrived within TMO_*.
    logic       wait_q, wait_psw;      // in a Q-Channel / power-switch wait, still waiting
    logic [2:0] wait_step;             // FAULT_INFO.STEP if this wait times out
    always_comb begin
        wait_q = 1'b0; wait_psw = 1'b0; wait_step = 3'd0;
        unique case (st)
            D_QWAIT:    begin wait_q   = !(q_stopped || q_deny); wait_step = FAULT_STEP_QACCEPT_DOWN;   end
            D_DENY:     begin wait_q   = !q_run;                 wait_step = FAULT_STEP_QDENY_RELEASE;  end
            U_QEXIT:    begin wait_q   = !q_run;                 wait_step = FAULT_STEP_QACCEPT_UP;     end
            D_MAIN_OFF: begin wait_psw = main_ack;               wait_step = FAULT_STEP_PSW_MAIN_OFF;   end
            D_TRK_OFF:  begin wait_psw = trickle_ack;            wait_step = FAULT_STEP_PSW_TRICKLE_OFF; end
            U_TRK_ON:   begin wait_psw = !trickle_ack;           wait_step = FAULT_STEP_PSW_TRICKLE_ON; end
            U_MAIN_ON:  begin wait_psw = !main_ack;              wait_step = FAULT_STEP_PSW_MAIN_ON;    end
            default: ;
        endcase
    end
    logic to_q, to_psw;
    assign to_q   = wait_q   && (cnt1 >= tmo(tmo_qch));
    assign to_psw = wait_psw && (cnt1 >= tmo(tmo_psw));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // PMU reset: every domain OFF (SPEC section 8)
            st             <= S_OFF;
            last_stable    <= PD_STATE_OFF;
            seq_tgt        <= T_OFF;
            cnt            <= '0;
            hcnt           <= '0;
            armed          <= 1'b1;       // MODE_REQ resets to RUN: boot (D-003.8)
            ret_valid      <= 1'b0;
            clk_en         <= 1'b0;
            iso_en         <= 1'b1;
            ret_save       <= 1'b0;
            ret_restore    <= 1'b0;
            rst_n_o        <= 1'b0;
            psw_trickle_en <= 1'b0;
            psw_main_en    <= 1'b0;
            stop_req       <= 1'b0;
            exit_req       <= 1'b0;
            inrush_req_q   <= 1'b0;
            fault_q        <= 1'b0;
            resume_st      <= S_OFF;
            ev_deny        <= 1'b0;
            ev_fault       <= 1'b0;
            fault_step     <= 3'd0;
        end else begin
            ev_deny  <= 1'b0;
            ev_fault <= 1'b0;
            cnt      <= cnt1;
            if (arm) armed <= 1'b1;

            if (to_psw) begin
                // power-switch timeout: safe off configuration (SPEC 4.6)
                psw_trickle_en <= 1'b0;
                psw_main_en    <= 1'b0;
                iso_en         <= 1'b1;
                clk_en         <= 1'b0;
                rst_n_o        <= 1'b0;
                ret_save       <= 1'b0;
                ret_restore    <= 1'b0;
                inrush_req_q   <= 1'b0;
                fault_q        <= 1'b0;
                fault_step     <= wait_step;
                ev_fault       <= 1'b1;
                st             <= S_FAULT;
            end else if (to_q) begin
                // Q-Channel timeout: outputs held; IHI 0068D 2.1.2 forbids changing QREQn or
                // asserting reset mid-handshake (SPEC 4.6)
                fault_q        <= 1'b1;
                resume_st      <= st;
                fault_step     <= wait_step;
                ev_fault       <= 1'b1;
                st             <= S_FAULT;
            end else
            unique case (st)
                // ---------------------------------------------------------- stable states
                S_ON: begin
                    last_stable <= PD_STATE_ON;
                    if (armed && t != T_ON) begin
                        seq_tgt  <= t;
                        stop_req <= 1'b1;               // 4.1 step 1 / 4.2 CG-down
                        cnt      <= '0;
                        st       <= D_QWAIT;
                    end
                end
                S_CG: begin
                    last_stable <= PD_STATE_CLK_GATED;
                    if (armed && t == T_ON) begin
                        clk_en <= 1'b1;                 // 4.2 CG-up
                        cnt    <= '0;
                        st     <= C_CLK;
                    end else if (armed && (t == T_RET || t == T_OFF)) begin
                        seq_tgt <= t;
                        iso_en  <= 1'b1;                // 4.1 from step 4
                        cnt     <= '0;
                        st      <= D_ISO;
                    end
                end
                S_RET: begin
                    last_stable <= PD_STATE_RET;
                    if (armed && (t == T_ON || t == T_CG)) begin
                        inrush_req_q <= 1'b1;
                        st <= U_ARB;
                    end else if (armed && t == T_OFF) begin
                        ret_valid <= 1'b0;              // bookkeeping only (SPEC 3.1)
                        st        <= S_OFF;
                    end
                end
                S_OFF: begin
                    last_stable <= PD_STATE_OFF;
                    if (armed && (t == T_ON || t == T_CG)) begin
                        inrush_req_q <= 1'b1;
                        st <= U_ARB;
                    end
                end
                S_FAULT: begin
                    if (fault_clr) begin
                        cnt <= '0;
                        if (fault_q) st <= resume_st;   // resume the same wait, fresh timeout
                        else         st <= S_OFF;       // already in the safe off configuration
                    end
                end
                // ---------------------------------------------------------- power-down
                D_QWAIT: begin
                    if (q_stopped) begin                // accepted: Q_STOPPED
                        stop_req <= 1'b0;
                        clk_en   <= 1'b0;               // step 3
                        cnt      <= '0;
                        st       <= D_CLK;
                    end else if (q_deny) begin          // Q_DENIED: qch_master raises QREQn
                        stop_req <= 1'b0;
                        cnt      <= '0;
                        st       <= D_DENY;
                    end
                end
                D_DENY: begin
                    if (q_run) begin                    // Q_CONTINUE -> Q_RUN: stay ON
                        armed   <= 1'b0;                // no retry until the next request (D-003.2)
                        ev_deny <= 1'b1;
                        st      <= S_ON;
                    end
                end
                D_CLK: if (hold_done) begin
                    cnt <= '0;
                    if (seq_tgt == T_CG) st <= S_CG;
                    else begin
                        iso_en <= 1'b1;                 // step 4
                        st     <= D_ISO;
                    end
                end
                D_ISO: if (hold_done) begin
                    cnt <= '0;
                    if (HAS_RET && seq_tgt == T_RET) begin
                        ret_save <= 1'b1;               // step 5
                        st       <= D_SAVE;
                    end else begin
                        rst_n_o <= 1'b0;                // step 6
                        st      <= D_RST;
                    end
                end
                D_SAVE: if (hold_done) begin
                    ret_save  <= 1'b0;
                    ret_valid <= 1'b1;
                    rst_n_o   <= 1'b0;
                    cnt       <= '0;
                    st        <= D_RST;
                end
                D_RST: if (hold_done) begin
                    psw_main_en <= 1'b0;                // step 7a: main first
                    cnt         <= '0;
                    st          <= D_MAIN_OFF;
                end
                D_MAIN_OFF: begin
                    if (!main_ack) begin
                        psw_trickle_en <= 1'b0;         // step 7b: then trickle
                        cnt            <= '0;
                        st             <= D_TRK_OFF;
                    end
                end
                D_TRK_OFF: begin
                    if (!trickle_ack) begin             // step 8: switched off
                        if (seq_tgt == T_RET && HAS_RET) st <= S_RET;
                        else begin
                            ret_valid <= 1'b0;
                            st        <= S_OFF;
                        end
                    end
                end
                // ---------------------------------------------------------- power-up
                U_ARB: if (inrush_gnt) begin
                    psw_trickle_en <= 1'b1;             // step 1
                    cnt            <= '0;
                    hcnt           <= '0;
                    st             <= U_TRK_ON;
                end
                U_TRK_ON: begin
                    if (trickle_ack) begin
                        hcnt <= hcnt + 16'd1;
                        if ({1'b0, hcnt} + 17'd1 >= dly(dly_trickle)) begin
                            psw_main_en <= 1'b1;        // step 3, after DLY_TRICKLE (property 4)
                            cnt         <= '0;
                            hcnt        <= '0;
                            st          <= U_MAIN_ON;
                        end
                    end else begin
                        hcnt <= '0;
                    end
                end
                U_MAIN_ON: begin
                    if (main_ack) begin
                        hcnt <= hcnt + 16'd1;
                        if ({1'b0, hcnt} + 17'd1 >= dly(dly_main)) begin
                            inrush_req_q <= 1'b0;       // end of the switching phase: release
                            cnt          <= '0;
                            if (HAS_RET && ret_valid) begin
                                ret_restore <= 1'b1;    // step 5
                                st          <= U_RESTORE;
                            end else begin
                                rst_n_o <= 1'b1;        // step 6
                                st      <= U_RST;
                            end
                        end
                    end else begin
                        hcnt <= '0;
                    end
                end
                U_RESTORE: if (hold_done) begin
                    ret_restore <= 1'b0;
                    ret_valid   <= 1'b0;
                    rst_n_o     <= 1'b1;                // step 6
                    cnt         <= '0;
                    st          <= U_RST;
                end
                U_RST: if (hold_done) begin
                    clk_en <= 1'b1;                     // step 7
                    cnt    <= '0;
                    st     <= U_CLK;
                end
                U_CLK: if (hold_done) begin
                    iso_en <= 1'b0;                     // step 8: isolation released last
                    st     <= U_ISO;
                end
                U_ISO: begin
                    exit_req <= 1'b1;                   // step 9: Q-Channel exit
                    cnt      <= '0;
                    st       <= U_QEXIT;
                end
                U_QEXIT: begin
                    if (q_run) begin
                        exit_req <= 1'b0;
                        st       <= S_ON;
                    end
                end
                C_CLK: if (hold_done) begin
                    exit_req <= 1'b1;
                    cnt      <= '0;
                    st       <= U_QEXIT;
                end
                default: st <= S_FAULT;                 // unreachable (property 8)
            endcase
        end
    end

    // ------------------------------------------------------------------ status
    logic stable;
    assign stable       = (st == S_ON) || (st == S_CG) || (st == S_RET) || (st == S_OFF);
    assign busy         = !stable && (st != S_FAULT);
    assign in_pu_switch = (st == U_TRK_ON) || (st == U_MAIN_ON);
    assign st_o         = st;
    always_comb begin
        unique case (st)
            S_ON:    pd_state = PD_STATE_ON;
            S_CG:    pd_state = PD_STATE_CLK_GATED;
            S_RET:   pd_state = PD_STATE_RET;
            S_OFF:   pd_state = PD_STATE_OFF;
            S_FAULT: pd_state = PD_STATE_FAULT;
            default: pd_state = last_stable;    // in a sequence: the state it started from
        endcase
    end
    // target satisfied (SPEC 3.2): exact, except that OFF also satisfies RET
    assign at_tgt = ((st == S_ON)  && t == T_ON)  ||
                    ((st == S_CG)  && t == T_CG)  ||
                    ((st == S_RET) && t == T_RET) ||
                    ((st == S_OFF) && (t == T_OFF || t == T_RET));
endmodule
