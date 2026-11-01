// sync_ff: STAGES-flop synchroniser for an asynchronous level input (SPEC section 1).
// Q-Channel responses, power-switch acks and wake_irq come from other clock/power domains
// (ARM IHI 0068D section 2.1.1: "All signals are assumed to be asynchronous").
module sync_ff #(
    parameter int     STAGES = 2,
    parameter logic   RESET_VAL = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic d,
    output logic q
);
    logic [STAGES-1:0] s;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s <= {STAGES{RESET_VAL}};
        else        s <= {s[STAGES-2:0], d};
    end

    assign q = s[STAGES-1];
endmodule
