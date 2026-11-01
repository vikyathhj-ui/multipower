// Audit probe for the legacy design (docs/AUDIT.md). Not part of the original project.
// Each probe prints a line "PROBE <id>: ..." that scripts/legacy_probe.sh collects.
`timescale 1ns/1ps
module tb_probe;
    reg clk = 0, rst = 1, enable_dsp = 0, enable_mem = 0;
    always #5 clk = ~clk;

    wire dsp_pg_n, dsp_iso, dsp_save, dsp_restore, dsp_act;
    wire mem_pg_n, mem_iso, mem_save, mem_restore, mem_act;
    wire [1:0] dsp_st, mem_st;
    wire any_act, inrush_safe;
    wire [7:0] dlat, mlat, dcnt, mcnt;

    power_manager_v3 u_pm (
        .clk(clk), .rst(rst), .enable_dsp(enable_dsp), .enable_mem(enable_mem),
        .dsp_power_gate_n(dsp_pg_n), .dsp_iso_en(dsp_iso), .dsp_save(dsp_save),
        .dsp_restore(dsp_restore), .dsp_active(dsp_act), .dsp_state(dsp_st),
        .mem_power_gate_n(mem_pg_n), .mem_iso_en(mem_iso), .mem_save(mem_save),
        .mem_restore(mem_restore), .mem_active(mem_act), .mem_state(mem_st),
        .any_domain_active(any_act), .inrush_safe(inrush_safe),
        .dsp_wakeup_latency(dlat), .mem_wakeup_latency(mlat),
        .dsp_transition_count(dcnt), .mem_transition_count(mcnt));

    localparam WAKE = 2'b01;
    integer cyc = 0, t_req, overlap = 0, overlap_safe = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg past_pg = 0, past_iso = 1;
    always @(posedge clk) begin past_pg <= dsp_pg_n; past_iso <= dsp_iso; end

    // P1: the power-up "sequence" is a fixed timer. Log the cycle of every event after the request.
    always @(posedge clk) if (!rst) begin
        if (dsp_pg_n && !past_pg) $display("PROBE P1: power_gate_n rises %0d cycles after enable", cyc - t_req);
        if (dsp_restore)           $display("PROBE P1: restore pulse    %0d cycles after enable", cyc - t_req);
        if (!dsp_iso && past_iso) $display("PROBE P1: iso_en falls     %0d cycles after enable", cyc - t_req);
    end

    // P2: inrush - count cycles where both domains are in WAKE (switching) at once.
    always @(posedge clk) if (!rst && dsp_st == WAKE && mem_st == WAKE) begin
        overlap = overlap + 1;
        if (inrush_safe) overlap_safe = overlap_safe + 1;
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        // P1: DSP power-up. There is no acknowledge input to wait for: the port list has none.
        @(negedge clk); enable_dsp = 1; t_req = cyc;
        wait (dsp_st == 2'b10);
        repeat (4) @(posedge clk);
        // P2: drop enable_dsp, let DSP go fully OFF, then request DSP and, one cycle later,
        // withdraw it while requesting MEM. DSP's WAKE does not check enable_dsp, so it keeps
        // switching; MEM's start condition (dsp_stagger_done || !enable_dsp) is now true.
        @(negedge clk); enable_dsp = 0;
        wait (dsp_st == 2'b00);
        @(negedge clk); enable_dsp = 1; t_req = cyc;
        @(negedge clk); enable_dsp = 0; enable_mem = 1;
        repeat (30) @(posedge clk);
        $display("PROBE P2: cycles with DSP and MEM both in WAKE (power-up switching) = %0d", overlap);
        $display("PROBE P2: of those, cycles with inrush_safe=1 = %0d", overlap_safe);
        $display("PROBE P2: final inrush_safe = %b (set once in MEM OFF->WAKE, cleared only by reset)", inrush_safe);
        $finish;
    end
endmodule
