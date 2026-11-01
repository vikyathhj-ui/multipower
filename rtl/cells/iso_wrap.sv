// iso_wrap: isolation cell on a signal leaving a switchable domain (BRIEF A4 "Isolation").
// iso_en = 1 forces the output to CLAMP. With PMU_SKY130_CELLS defined, the sky130 low-power
// isolation cells are instantiated (liberty functions, results/env_check.txt):
//   CLAMP 0: sky130_fd_sc_hd__lpflow_inputiso0p_1, X = !SLEEP & A
//   CLAMP 1: sky130_fd_sc_hd__lpflow_inputiso1p_1, X = A | SLEEP
// Otherwise a behavioural clamp is used for simulation and formal.
module iso_wrap #(
    parameter logic CLAMP = 1'b0
) (
    input  logic d,       // from the switchable domain
    input  logic iso_en,  // from the PMU (always on)
    output logic q        // to the always-on side
);
`ifdef PMU_SKY130_CELLS
    if (CLAMP == 1'b0) begin : g_c0
        sky130_fd_sc_hd__lpflow_inputiso0p_1 u_iso (.A(d), .SLEEP(iso_en), .X(q));
    end else begin : g_c1
        sky130_fd_sc_hd__lpflow_inputiso1p_1 u_iso (.A(d), .SLEEP(iso_en), .X(q));
    end
`else
    assign q = iso_en ? CLAMP : d;
`endif
endmodule
