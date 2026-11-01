// rst_sync: reset synchroniser. Assertion is asynchronous (PRESETn low clears every flop at once);
// release is synchronised to clk through two flops, so no flop sees reset removal near a clock edge.
module rst_sync (
    input  logic clk,
    input  logic rst_n_in,   // PRESETn
    output logic rst_n       // to every flop in the PMU
);
    // A reset synchroniser is the one place a flop is both reset asynchronously and drives
    // reset: Verilator's SYNCASYNCNET is expected here.
    /* verilator lint_off SYNCASYNCNET */
    logic [1:0] s;
    /* verilator lint_on SYNCASYNCNET */

    always_ff @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) s <= 2'b00;
        else           s <= {s[0], 1'b1};
    end

    assign rst_n = s[1];
endmodule
