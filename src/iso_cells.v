// =============================================
// Isolation Cell Library
// AND-type: output=0 when iso_en=1
// OR-type:  output=1 when iso_en=1
// Level Shifter: 1.8V → 1.2V (behavioral)
// =============================================

// AND isolation cell (clamp to 0)
module iso_and (
    input  iso_en,
    input  data_in,
    output data_out
);
    assign data_out = data_in & ~iso_en;
endmodule

// OR isolation cell (clamp to 1)
module iso_or (
    input  iso_en,
    input  data_in,
    output data_out
);
    assign data_out = data_in | iso_en;
endmodule

// Bus isolation cell (32-bit)
module iso_bus32 (
    input         iso_en,
    input  [31:0] data_in,
    output [31:0] data_out
);
    assign data_out = iso_en ? 32'h0 : data_in;
endmodule

// Level shifter 1.8V to 1.2V (behavioral model)
module level_shifter_HL (
    input  data_in,   // 1.8V domain
    output data_out   // 1.2V domain
);
    // Behavioral: in real silicon this would be
    // a dedicated level-shifter cell from PDK
    // Adds 0.2ns propagation delay model
    assign #(2) data_out = data_in;
endmodule

// Bus level shifter 32-bit
module level_shifter_bus32 (
    input  [31:0] data_in,
    output [31:0] data_out
);
    genvar i;
    generate
        for (i=0; i<32; i=i+1) begin : LS
            level_shifter_HL ls_bit (
                .data_in  (data_in[i]),
                .data_out (data_out[i])
            );
        end
    endgenerate
endmodule

// Retention register (save/restore flop)
module retention_ff (
    input  clk,
    input  rst,
    input  save,
    input  restore,
    input  data_in,
    output reg data_out,
    output reg ret_data
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_out <= 0;
            ret_data <= 0;
        end else if (save) begin
            ret_data <= data_in;  // save to retention
        end else if (restore) begin
            data_out <= ret_data; // restore from retention
        end else begin
            data_out <= data_in;
        end
    end
endmodule
