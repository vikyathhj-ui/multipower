// apb_regs: APB3 completer and the PMU registers (docs/REGMAP.md, docs/SPEC.md 2.1).
// Addresses and reset values come from pmu_regmap_pkg, generated from scripts/regmap.yaml.
//
// ARM IHI 0024E: zero wait states, PREADY = PSEL & PENABLE (high only in the access phase,
// section 4.1); PSLVERR only in the access phase (section 3.4) for an unmapped address, a write
// to a read-only register, or an illegal mode value. A transfer with an error changes nothing
// (DECISIONS D-003.9).
module apb_regs #(
    parameter int N_PD = 3
) (
    input  logic        clk,
    input  logic        rst_n,
    // APB3
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [11:0] paddr,          // [1:0] ignored: word-aligned registers (SPEC 2.1)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,
    // control to the core
    output logic [2:0]  mode_req,
    output logic        arm,            // pulse: new mode request (write or wake)
    output logic [7:0]  wake_mask,
    output logic [31:0] timer_cmp,
    output logic        timer_en,
    output logic        timer_start,    // pulse
    output logic [15:0] dly_trickle, dly_main, dly_clk, dly_iso, dly_ret, dly_rst,
    output logic [15:0] tmo_qch, tmo_psw,
    output logic        fault_clr,      // pulse: IRQ_STATUS.FAULT written 1
    output logic        irq,
    // status from the core
    input  logic [31:0] mode_status,
    input  logic [31:0] pd_state_reg,
    input  logic [31:0] timer_cnt,
    input  logic        timer_fire,
    input  logic        wake_evt,
    input  logic        ev_done,
    input  logic        ev_deny,                    // any domain
    input  logic [N_PD-1:0] ev_fault,               // per domain
    input  logic [N_PD*3-1:0] fault_step_vec        // per domain FAULT_INFO.STEP
);
    import pmu_regmap_pkg::*;

    logic [2:0]  wake_mode;
    logic [3:0]  irq_status, irq_en;
    logic [31:0] fault_info;

    // ------------------------------------------------------------- APB decode
    logic access, wr, rd;
    assign access = psel && penable;
    assign wr     = access && pwrite;
    assign rd     = access && !pwrite;
    assign pready = access;

    logic [11:0] a;
    assign a = {paddr[11:2], 2'b00};          // word-aligned; bits [1:0] ignored

    logic mapped, ro, bad_mode;
    always_comb begin
        mapped = 1'b1;
        ro     = 1'b0;
        unique case (a)
            ADDR_ID, ADDR_VERSION, ADDR_MODE_STATUS, ADDR_PD_STATE,
            ADDR_WAKE_TIMER, ADDR_FAULT_INFO:                         ro = 1'b1;
            ADDR_MODE_REQ, ADDR_WAKE_MODE, ADDR_WAKE_MASK, ADDR_WAKE_TIMER_CMP, ADDR_WAKE_CTRL,
            ADDR_DLY_TRICKLE, ADDR_DLY_MAIN, ADDR_DLY_CLK, ADDR_DLY_ISO, ADDR_DLY_RET,
            ADDR_DLY_RST, ADDR_TMO_QCH, ADDR_TMO_PSW, ADDR_IRQ_STATUS, ADDR_IRQ_EN:  ;
            default:                                                  mapped = 1'b0;
        endcase
    end
    assign bad_mode = (a == ADDR_MODE_REQ || a == ADDR_WAKE_MODE) && (pwdata[2:0] > MODE_SHUTDOWN);

    logic err, we;
    assign err     = access && (!mapped || (pwrite && (ro || bad_mode)));
    assign pslverr = err;                     // only in the access phase
    assign we      = wr && !err;              // a write that takes effect

    // ------------------------------------------------------------- read data
    always_comb begin
        prdata = '0;
        if (rd && mapped) begin
            unique case (a)
                ADDR_ID:             prdata = RST_ID;
                ADDR_VERSION:        prdata = RST_VERSION;
                ADDR_MODE_REQ:       prdata = {29'd0, mode_req};
                ADDR_MODE_STATUS:    prdata = mode_status;
                ADDR_PD_STATE:       prdata = pd_state_reg;
                ADDR_WAKE_MODE:      prdata = {29'd0, wake_mode};
                ADDR_WAKE_MASK:      prdata = {24'd0, wake_mask};
                ADDR_WAKE_TIMER_CMP: prdata = timer_cmp;
                ADDR_WAKE_TIMER:     prdata = timer_cnt;
                ADDR_WAKE_CTRL:      prdata = {31'd0, timer_en};
                ADDR_DLY_TRICKLE:    prdata = {16'd0, dly_trickle};
                ADDR_DLY_MAIN:       prdata = {16'd0, dly_main};
                ADDR_DLY_CLK:        prdata = {16'd0, dly_clk};
                ADDR_DLY_ISO:        prdata = {16'd0, dly_iso};
                ADDR_DLY_RET:        prdata = {16'd0, dly_ret};
                ADDR_DLY_RST:        prdata = {16'd0, dly_rst};
                ADDR_TMO_QCH:        prdata = {16'd0, tmo_qch};
                ADDR_TMO_PSW:        prdata = {16'd0, tmo_psw};
                ADDR_IRQ_STATUS:     prdata = {28'd0, irq_status};
                ADDR_IRQ_EN:         prdata = {28'd0, irq_en};
                ADDR_FAULT_INFO:     prdata = fault_info;
                default:             prdata = '0;
            endcase
        end
    end

    // ------------------------------------------------------------- first fault (FAULT_INFO)
    logic        any_fault;
    logic [1:0]  f_dom;
    logic [2:0]  f_step;
    always_comb begin                          // lowest-index domain if several fault at once
        f_dom  = '0;
        f_step = '0;
        for (int d = N_PD - 1; d >= 0; d--) begin
            if (ev_fault[d]) begin
                f_dom  = 2'(d);
                f_step = fault_step_vec[d*3 +: 3];
            end
        end
    end
    assign any_fault = |ev_fault;

    logic w1c_fault;
    assign w1c_fault = we && a == ADDR_IRQ_STATUS && pwdata[2];
    assign fault_clr = w1c_fault;

    // ------------------------------------------------------------- registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_req    <= RST_MODE_REQ[2:0];
            arm         <= 1'b0;
            wake_mode   <= RST_WAKE_MODE[2:0];
            wake_mask   <= RST_WAKE_MASK[7:0];
            timer_cmp   <= RST_WAKE_TIMER_CMP;
            timer_en    <= RST_WAKE_CTRL[0];
            timer_start <= 1'b0;
            dly_trickle <= RST_DLY_TRICKLE[15:0];
            dly_main    <= RST_DLY_MAIN[15:0];
            dly_clk     <= RST_DLY_CLK[15:0];
            dly_iso     <= RST_DLY_ISO[15:0];
            dly_ret     <= RST_DLY_RET[15:0];
            dly_rst     <= RST_DLY_RST[15:0];
            tmo_qch     <= RST_TMO_QCH[15:0];
            tmo_psw     <= RST_TMO_PSW[15:0];
            irq_status  <= RST_IRQ_STATUS[3:0];
            irq_en      <= RST_IRQ_EN[3:0];
            fault_info  <= RST_FAULT_INFO;
        end else begin
            arm         <= 1'b0;
            timer_start <= 1'b0;

            // MODE_REQ: a software write wins over a wake event in the same cycle
            if (we && a == ADDR_MODE_REQ) begin
                mode_req <= pwdata[2:0];
                arm      <= 1'b1;
            end else if (wake_evt) begin
                mode_req <= wake_mode;
                arm      <= 1'b1;
            end

            if (we && a == ADDR_WAKE_MODE)      wake_mode   <= pwdata[2:0];
            if (we && a == ADDR_WAKE_MASK)      wake_mask   <= pwdata[7:0];
            if (we && a == ADDR_WAKE_TIMER_CMP) timer_cmp   <= pwdata;
            if (we && a == ADDR_DLY_TRICKLE)    dly_trickle <= pwdata[15:0];
            if (we && a == ADDR_DLY_MAIN)       dly_main    <= pwdata[15:0];
            if (we && a == ADDR_DLY_CLK)        dly_clk     <= pwdata[15:0];
            if (we && a == ADDR_DLY_ISO)        dly_iso     <= pwdata[15:0];
            if (we && a == ADDR_DLY_RET)        dly_ret     <= pwdata[15:0];
            if (we && a == ADDR_DLY_RST)        dly_rst     <= pwdata[15:0];
            if (we && a == ADDR_TMO_QCH)        tmo_qch     <= pwdata[15:0];
            if (we && a == ADDR_TMO_PSW)        tmo_psw     <= pwdata[15:0];
            if (we && a == ADDR_IRQ_EN)         irq_en      <= pwdata[3:0];

            // WAKE_CTRL.TIMER_EN: software write, or cleared by the one-shot compare
            if (we && a == ADDR_WAKE_CTRL) begin
                timer_en    <= pwdata[0];
                timer_start <= pwdata[0];
            end else if (timer_fire) begin
                timer_en    <= 1'b0;
            end

            // IRQ_STATUS: write 1 to clear; a new event in the same cycle wins over the clear
            irq_status <= (irq_status & ~((we && a == ADDR_IRQ_STATUS) ? pwdata[3:0] : 4'd0))
                          | {wake_evt, any_fault, ev_deny, ev_done};

            // FAULT_INFO: the first fault since IRQ_STATUS.FAULT was cleared
            if (any_fault && (!fault_info[31] || w1c_fault))
                fault_info <= {1'b1, 24'd0, f_step, 2'b00, f_dom};   // VALID [31], STEP [6:4], DOMAIN [1:0]
            else if (w1c_fault)
                fault_info <= '0;
        end
    end

    assign irq = |(irq_status & irq_en);
endmodule
