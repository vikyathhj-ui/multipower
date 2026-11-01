// qch_master: Q-Channel controller side for one domain (ARM IHI 0068D Chapter 2; docs/SPEC.md 2.2).
// Drives QREQn from a register (IHI 0068D 2.1.1: "QREQn ... must all be driven by registers") and
// obeys the controller handshake rules (IHI 0068D 2.1.2, "Handshake rules", p. 2-23):
//   QREQn may fall only when QACCEPTn = 1 and QDENY = 0 (Q_RUN);
//   QREQn may rise only when QACCEPTn and QDENY are both 0 (Q_STOPPED -> Q_EXIT)
//   or both 1 (Q_DENIED -> Q_CONTINUE).
// The device inputs arrive synchronised (sync_ff) and, while the domain is isolated, clamped to 0.
module qch_master (
    input  logic clk,
    input  logic rst_n,
    input  logic stop_req,      // from pd_ctrl: request quiescence
    input  logic exit_req,      // from pd_ctrl: leave Q_STOPPED
    input  logic qacceptn,      // synchronised QACCEPTn
    input  logic qdeny,         // synchronised QDENY
    output logic qreqn,         // QREQn to the device
    output logic q_run,         // Q_RUN:     QREQn=1 QACCEPTn=1 QDENY=0
    output logic q_stopped      // Q_STOPPED: QREQn=0 QACCEPTn=0 QDENY=0
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Controller and device reset together; the device is OFF and in reset, and the
            // interface is in Q_STOPPED (IHI 0068D 2.1.2, "Device reset").
            qreqn <= 1'b0;
        end else if (qreqn) begin
            if (stop_req && qacceptn && !qdeny) qreqn <= 1'b0;   // Q_RUN -> Q_REQUEST
        end else begin
            if (qacceptn && qdeny)               qreqn <= 1'b1;   // Q_DENIED -> Q_CONTINUE
            else if (exit_req && !qacceptn && !qdeny) qreqn <= 1'b1; // Q_STOPPED -> Q_EXIT
        end
    end

    assign q_run     =  qreqn &&  qacceptn && !qdeny;
    assign q_stopped = !qreqn && !qacceptn && !qdeny;
endmodule
