// =============================================
// Top Level v3 — Full UPF-compliant design
// 3 Power Domains:
//   AON:  power_manager (always on)
//   DSP:  1.8V — MAC unit
//   MEM:  1.2V — buffer unit
//
// Explicit cells:
//   - Isolation cells on all cross-domain outputs
//   - Level shifters at DSP(1.8V)→MEM(1.2V)
//   - Retention registers in each gated domain
// =============================================
module top_power_v3 (
    input         clk,
    input         rst,
    input         enable_dsp,
    input         enable_mem,
    input  [15:0] data_a,
    input  [15:0] data_b,
    input         data_valid,
    // Final outputs
    output [31:0] mac_result,
    output        result_valid,
    output [31:0] mem_out,
    output        buffer_full,
    // Status
    output        dsp_active,
    output        mem_active,
    output        any_active,
    output        inrush_safe,
    output [1:0]  dsp_state,
    output [1:0]  mem_state,
    // Metrics
    output [7:0]  dsp_wakeup_latency,
    output [7:0]  mem_wakeup_latency,
    output [7:0]  dsp_transitions,
    output [7:0]  mem_transitions,
    output [7:0]  dsp_retained_regs,
    output [7:0]  mem_retained_regs,
    output        dsp_restore_success
);

// Power control wires
wire dsp_power_gate_n, dsp_iso_en, dsp_save, dsp_restore;
wire mem_power_gate_n, mem_iso_en, mem_save, mem_restore;

// DSP raw outputs (pre-isolation)
wire [31:0] dsp_raw_result;
wire        dsp_raw_valid;

// Isolated DSP outputs
wire [31:0] dsp_iso_result;
wire        dsp_iso_valid;

// Level-shifted signals (DSP 1.8V → MEM 1.2V)
wire [31:0] ls_result;
wire        ls_valid;

// AON Power Manager
power_manager_v3 u_pm (
    .clk                (clk),
    .rst                (rst),
    .enable_dsp         (enable_dsp),
    .enable_mem         (enable_mem),
    .dsp_power_gate_n   (dsp_power_gate_n),
    .dsp_iso_en         (dsp_iso_en),
    .dsp_save           (dsp_save),
    .dsp_restore        (dsp_restore),
    .dsp_active         (dsp_active),
    .dsp_state          (dsp_state),
    .mem_power_gate_n   (mem_power_gate_n),
    .mem_iso_en         (mem_iso_en),
    .mem_save           (mem_save),
    .mem_restore        (mem_restore),
    .mem_active         (mem_active),
    .mem_state          (mem_state),
    .any_domain_active  (any_active),
    .inrush_safe        (inrush_safe),
    .dsp_wakeup_latency (dsp_wakeup_latency),
    .mem_wakeup_latency (mem_wakeup_latency),
    .dsp_transition_count(dsp_transitions),
    .mem_transition_count(mem_transitions)
);

// DSP Domain (1.8V)
dsp_domain_v3 u_dsp (
    .clk                (clk),
    .rst                (rst),
    .iso_en             (dsp_iso_en),
    .save               (dsp_save),
    .restore            (dsp_restore),
    .data_a             (data_a),
    .data_b             (data_b),
    .data_valid         (data_valid & dsp_power_gate_n),
    .raw_result         (dsp_raw_result),
    .raw_valid          (dsp_raw_valid),
    .domain_busy        (),
    .retained_reg_count (dsp_retained_regs),
    .restore_success    (dsp_restore_success)
);

// =============================================
// ISOLATION CELLS (DSP outputs → AON/MEM)
// Assert iso_en=1 clamps outputs to 0
// =============================================
iso_bus32 u_iso_result (
    .iso_en   (dsp_iso_en),
    .data_in  (dsp_raw_result),
    .data_out (dsp_iso_result)
);

iso_and u_iso_valid (
    .iso_en   (dsp_iso_en),
    .data_in  (dsp_raw_valid),
    .data_out (dsp_iso_valid)
);

// Expose isolated DSP outputs
assign mac_result   = dsp_iso_result;
assign result_valid = dsp_iso_valid;

// =============================================
// LEVEL SHIFTERS (DSP 1.8V → MEM 1.2V)
// Required whenever crossing voltage domains
// =============================================
level_shifter_bus32 u_ls_result (
    .data_in  (dsp_iso_result),
    .data_out (ls_result)
);

level_shifter_HL u_ls_valid (
    .data_in  (dsp_iso_valid),
    .data_out (ls_valid)
);

// MEM Domain (1.2V)
mem_domain_v3 u_mem (
    .clk                (clk),
    .rst                (rst),
    .iso_en             (mem_iso_en),
    .save               (mem_save),
    .restore            (mem_restore),
    .data_in            (ls_result),
    .data_valid         (ls_valid & mem_power_gate_n),
    .mem_out            (mem_out),
    .buffer_full        (buffer_full),
    .fill_level         (),
    .retained_reg_count (mem_retained_regs)
);

endmodule
