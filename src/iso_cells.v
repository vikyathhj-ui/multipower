module iso_and (
    input  iso_en,
    input  data_in,
    output data_out
);
    assign data_out = data_in & ~iso_en;
endmodule

module iso_or (
    input  iso_en,
    input  data_in,
    output data_out
);
    assign data_out = data_in | iso_en;
endmodule

module iso_bus32 (
    input         iso_en,
    input  [31:0] data_in,
    output [31:0] data_out
);
    assign data_out = iso_en ? 32'h0 : data_in;
endmodule

// Level shifter — pure combinational for synthesis
// In real silicon, PDK provides actual level shifter cell
module level_shifter_HL (
    input  data_in,
    output data_out
);
    assign data_out = data_in;
endmodule

module level_shifter_bus32 (
    input  [31:0] data_in,
    output [31:0] data_out
);
    assign data_out = data_in;
endmodule

module retention_ff (
    input      clk,
    input      rst,
    input      save,
    input      restore,
    input      data_in,
    output reg data_out,
    output reg ret_data
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_out <= 0;
            ret_data <= 0;
        end else if (save) begin
            ret_data <= data_in;
        end else if (restore) begin
            data_out <= ret_data;
        end else begin
            data_out <= data_in;
        end
    end
endmodule
