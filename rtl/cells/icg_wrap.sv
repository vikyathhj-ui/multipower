// icg_wrap: integrated clock gate for one switchable domain (BRIEF A4 "Clock gating").
// With PMU_SKY130_CELLS defined, the sky130 ICG sky130_fd_sc_hd__dlclkp_1 is instantiated
// (liberty: GCLK = CLK & M0, M0 = GATE latched while CLK is low; results/env_check.txt).
// Otherwise a behavioural model of the same cell is used for simulation and formal.
// An ICG, unlike an AND gate, latches the enable while the clock is low, so a change of en
// can never shorten or glitch a clock pulse.
module icg_wrap (
    input  logic clk,
    input  logic en,
    output logic gclk
);
`ifdef PMU_SKY130_CELLS
    sky130_fd_sc_hd__dlclkp_1 u_icg (.CLK(clk), .GATE(en), .GCLK(gclk));
`else
    logic en_l;
    // Transparent-low latch: the intended latch of a clock-gating cell.
    always_latch begin
        if (!clk) en_l = en;
    end
    assign gclk = clk & en_l;
`endif
endmodule
