module power_manager_v3 (
    input        clk,
    input        rst,
    input        enable_dsp,
    input        enable_mem,
    output reg   dsp_power_gate_n,
    output reg   dsp_iso_en,
    output reg   dsp_save,
    output reg   dsp_restore,
    output reg   dsp_active,
    output [1:0] dsp_state,
    output reg   mem_power_gate_n,
    output reg   mem_iso_en,
    output reg   mem_save,
    output reg   mem_restore,
    output reg   mem_active,
    output [1:0] mem_state,
    output reg   any_domain_active,
    output reg   inrush_safe,
    output reg [7:0] dsp_wakeup_latency,
    output reg [7:0] mem_wakeup_latency,
    output reg [7:0] dsp_transition_count,
    output reg [7:0] mem_transition_count
);

localparam OFF   = 2'b00;
localparam WAKE  = 2'b01;
localparam ON    = 2'b10;
localparam SLEEP = 2'b11;

reg [1:0] dsp_st, mem_st;
assign dsp_state = dsp_st;
assign mem_state = mem_st;

reg [7:0] dsp_cnt, mem_cnt;
reg       dsp_stagger_done;

// DSP FSM
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dsp_st              <= OFF;
        dsp_power_gate_n    <= 0;
        dsp_iso_en          <= 1;
        dsp_save            <= 0;
        dsp_restore         <= 0;
        dsp_active          <= 0;
        dsp_cnt             <= 0;
        dsp_wakeup_latency  <= 0;
        dsp_transition_count<= 0;
        dsp_stagger_done    <= 0;
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
                    dsp_st  <= WAKE;
                    dsp_cnt <= 0;
                end
            end
            WAKE: begin
                dsp_cnt <= dsp_cnt + 1;
                if (dsp_cnt == 8'd4)
                    dsp_power_gate_n <= 1;
                if (dsp_cnt == 8'd8)
                    dsp_restore <= 1;
                if (dsp_cnt == 8'd12) begin
                    dsp_iso_en          <= 0;
                    dsp_active          <= 1;
                    dsp_wakeup_latency  <= dsp_cnt;
                    dsp_transition_count<= dsp_transition_count + 1;
                    dsp_stagger_done    <= 1;
                    dsp_st              <= ON;
                end
            end
            ON: begin
                dsp_power_gate_n <= 1;
                dsp_iso_en       <= 0;
                dsp_active       <= 1;
                if (!enable_dsp) begin
                    dsp_iso_en <= 1;
                    dsp_st     <= SLEEP;
                    dsp_cnt    <= 0;
                end
            end
            SLEEP: begin
                dsp_cnt <= dsp_cnt + 1;
                if (dsp_cnt == 8'd2)
                    dsp_save <= 1;
                if (dsp_cnt == 8'd6) begin
                    dsp_power_gate_n <= 0;
                    dsp_active       <= 0;
                end
                if (dsp_cnt == 8'd10) begin
                    dsp_st              <= OFF;
                    dsp_transition_count<= dsp_transition_count + 1;
                end
            end
        endcase
    end
end

// MEM FSM
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mem_st              <= OFF;
        mem_power_gate_n    <= 0;
        mem_iso_en          <= 1;
        mem_save            <= 0;
        mem_restore         <= 0;
        mem_active          <= 0;
        mem_cnt             <= 0;
        mem_wakeup_latency  <= 0;
        mem_transition_count<= 0;
        inrush_safe         <= 0;
    end else begin
        mem_save    <= 0;
        mem_restore <= 0;
        case (mem_st)
            OFF: begin
                mem_power_gate_n <= 0;
                mem_iso_en       <= 1;
                mem_active       <= 0;
                if (enable_mem && (dsp_stagger_done || !enable_dsp)) begin
                    mem_st      <= WAKE;
                    mem_cnt     <= 0;
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
                    mem_iso_en          <= 0;
                    mem_active          <= 1;
                    mem_wakeup_latency  <= mem_cnt;
                    mem_transition_count<= mem_transition_count + 1;
                    mem_st              <= ON;
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
                    mem_st              <= OFF;
                    mem_transition_count<= mem_transition_count + 1;
                end
            end
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) any_domain_active <= 0;
    else     any_domain_active <= dsp_active | mem_active;
end

endmodule
