// inrush_arb: lets at most one domain be in its power-up switching phase (docs/SPEC.md 4.4, 5).
// Fixed priority, lowest index first: CPU (0) > DSP (1) > PERI (2). A grant is held for as long
// as its holder keeps requesting (no preemption). The grant is registered, so a new grant appears
// only after the previous holder has dropped its request, i.e. left the switching phase.
module inrush_arb #(
    parameter int N = 3
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [N-1:0] req,
    output logic [N-1:0] gnt
);
    logic [N-1:0] pick;     // lowest-index requester, one-hot (or 0)
    always_comb begin
        pick = '0;
        for (int i = 0; i < N; i++) begin
            if (req[i] && pick == '0) pick[i] = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 gnt <= '0;
        else if (|(gnt & req))      gnt <= gnt;    // holder still in its phase: keep
        else                        gnt <= pick;
    end
endmodule
