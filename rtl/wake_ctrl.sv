// wake_ctrl: wake sources (docs/SPEC.md section 7).
// A wake event is a rising edge on an unmasked wake_irq bit (after synchronisation), or the
// 32-bit AON wake timer reaching WAKE_TIMER_CMP while enabled. The timer is one-shot: the register
// block clears WAKE_CTRL.TIMER_EN when timer_fire pulses.
module wake_ctrl (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  wake_irq_s,    // synchronised wake_irq
    input  logic [7:0]  wake_mask,     // 1 = masked
    input  logic        timer_en,
    input  logic        timer_start,   // pulse: TIMER_EN written 1 (clears the count)
    input  logic [31:0] timer_cmp,
    output logic [31:0] timer_cnt,
    output logic        timer_fire,    // pulse
    output logic        wake_evt       // pulse
);
    logic [7:0] prev;
    logic       irq_rise;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev <= '0;
        else        prev <= wake_irq_s;
    end
    assign irq_rise = |(wake_irq_s & ~prev & ~wake_mask);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           timer_cnt <= '0;
        else if (timer_start) timer_cnt <= '0;
        else if (timer_en)    timer_cnt <= timer_cnt + 32'd1;
    end
    assign timer_fire = timer_en && !timer_start && (timer_cnt == timer_cmp);

    assign wake_evt = irq_rise || timer_fire;
endmodule
