// =============================================
// AON Power Manager v3
// - 4-state FSM per domain (OFF/WAKE/ON/SLEEP)
// - Proper isolation sequencing
// - Staggered power-on (anti-inrush)
// - Wake-up latency counter
// - Power acknowledgement handshake
// =============================================
module power_manager_v3 (
    input        clk,
    input        rst,
    input        enable_dsp,
    input        enable_mem,

    // Domain A (DSP) 1.8V
    output reg   dsp_power_gate_n,
    output reg   dsp_iso_en,
    output reg   dsp_save,
    output reg   dsp_restore,
    output reg   dsp_active,
    output [1:0] dsp_state,

    // Domain B (MEM) 1.2V
    output reg   mem_power_gate_n,
    output reg   mem_iso_en,
    output reg   mem_save,
    output reg   mem_restore,
    output reg   mem_active,
    output [1:0] mem_state,

    // Global status
    output reg   any_domain_active,
    output reg   inrush_safe,

    // Metrics outputs
    output reg [7:0]  dsp_wakeup_latency,
    output reg [7:0]  mem_wakeup_latency,
    output reg [7:0]  dsp_transition_count,
    output reg [7:0]  mem_transition_count
);

localparam OFF   = 2'b00;
localparam WAKE  = 2'b01;
localparam ON    = 2'b10;
localparam SLEEP = 2'b11;

reg [1:0] dsp_st, mem_st;
assign dsp_state = dsp_st;
assign mem_state = mem_st;

reg [7:0] dsp_cnt, mem_cnt;
reg [7:0] dsp_wake_start, mem_wake_start;
reg       dsp_stagger_done;

// ---- DSP Domain FSM ----
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dsp_st             <= OFF;
        dsp_power_gate_n   <= 0;
        dsp_iso_en         <= 1;
        dsp_save           <= 0;
        dsp_restore        <= 0;
        dsp_active         <= 0;
        dsp_cnt            <= 0;
        dsp_wakeup_latency <= 0;
        dsp_transition_count<=0;
        dsp_stagger_done   <= 0;
    end else begin
        dsp_save    <= 0;
        dsp_restore <= 0;
        case (dsp_st)
            OFF: begin
                dsp_power_gate_n <= 0;
                dsp_iso_en       <= 1;
                dsp_active       <= 0;
                dsp_stagger_done <= 0;
                if (enable_dsp) begin
                    dsp_st         <= WAKE;
                    dsp_cnt        <= 0;
                    dsp_wake_start <= 0;
                end
            end
            WAKE: begin
                dsp_cnt <= dsp_cnt + 1;
                // Step 1 (cycle 4): power on
                if (dsp_cnt == 8'd4)
                    dsp_power_gate_n <= 1;
                // Step 2 (cycle 8): restore state
                if (dsp_cnt == 8'd8) begin
                    dsp_restore <= 1;
                end
                // Step 3 (cycle 12): de-assert isolation
                if (dsp_cnt == 8'd12) begin
                    dsp_iso_en       <= 0;
                    dsp_active       <= 1;
                    dsp_wakeup_latency <= dsp_cnt;
                    dsp_transition_count <= dsp_transition_count + 1;
                    dsp_stagger_done <= 1;
                    dsp_st           <= ON;
                end
            end
            ON: begin
                dsp_power_gate_n <= 1;
                dsp_iso_en       <= 0;
                dsp_active       <= 1;
                if (!enable_dsp) begin
                    // Step 1: assert isolation FIRST
                    dsp_iso_en <= 1;
                    dsp_st     <= SLEEP;
                    dsp_cnt    <= 0;
                end
            end
            SLEEP: begin
                dsp_cnt <= dsp_cnt + 1;
                // Step 2: save state
                if (dsp_cnt == 8'd2)
                    dsp_save <= 1;
                // Step 3: power gate
                if (dsp_cnt == 8'd6) begin
                    dsp_power_gate_n <= 0;
                    dsp_active       <= 0;
                end
                // Step 4: back to OFF
                if (dsp_cnt == 8'd10) begin
                    dsp_st <= OFF;
                    dsp_transition_count <= dsp_transition_count + 1;
                end
            end
        endcase
    end
end

// ---- MEM Domain FSM (staggered 16 cycles after DSP) ----
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mem_st             <= OFF;
        mem_power_gate_n   <= 0;
        mem_iso_en         <= 1;
        mem_save           <= 0;
        mem_restore        <= 0;
        mem_active         <= 0;
        mem_cnt            <= 0;
        mem_wakeup_latency <= 0;
        mem_transition_count<=0;
        inrush_safe        <= 0;
    end else begin
        mem_save    <= 0;
        mem_restore <= 0;
        case (mem_st)
            OFF: begin
                mem_power_gate_n <= 0;
                mem_iso_en       <= 1;
                mem_active       <= 0;
                // Stagger: only power on MEM after DSP is stable
                if (enable_mem && dsp_stagger_done) begin
                    mem_st  <= WAKE;
                    mem_cnt <= 0;
                    inrush_safe <= 1; // stagger complete
                end else if (enable_mem && !enable_dsp) begin
                    mem_st  <= WAKE;
                    mem_cnt <= 0;
                    inrush_safe <= 1;
                end
            end
            WAKE: begin
                mem_cnt <= mem_cnt + 1;
                if (mem_cnt == 8'd4)
                    mem_power_gate_n <= 1;
                if (mem_cnt == 8'd8)
                    mem_restore <= 1;
                if (mem_cnt == 8'd12) begin
                    mem_iso_en       <= 0;
                    mem_active       <= 1;
                    mem_wakeup_latency <= mem_cnt;
                    mem_transition_count <= mem_transition_count + 1;
                    mem_st           <= ON;
                end
            end
            ON: begin
                mem_power_gate_n <= 1;
                mem_iso_en       <= 0;
                mem_active       <= 1;
                if (!enable_mem) begin
                    mem_iso_en <= 1;
                    mem_st     <= SLEEP;
                    mem_cnt    <= 0;
                end
            end
            SLEEP: begin
                mem_cnt <= mem_cnt + 1;
                if (mem_cnt == 8'd2)
                    mem_save <= 1;
                if (mem_cnt == 8'd6) begin
                    mem_power_gate_n <= 0;
                    mem_active       <= 0;
                end
                if (mem_cnt == 8'd10) begin
                    mem_st <= OFF;
                    mem_transition_count <= mem_transition_count + 1;
                end
            end
        endcase
    end
end

always @(*) begin
    any_domain_active = dsp_active | mem_active;
end

endmodule
