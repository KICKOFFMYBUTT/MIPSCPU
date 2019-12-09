`include "constants.v"
module CPU (
           input clk,
           input reset
       );

reg [31:0] W_pc;
wire D_data_waiting;
wire E_data_waiting;
wire M_data_waiting;
reg [2:0] stallLevel;
always @(*) begin
    stallLevel = `stallNone;
    if (D_data_waiting) begin
        stallLevel = `stallDecode;
    end
    if (E_data_waiting) begin
        stallLevel = `stallExecution;
    end
    if (M_data_waiting) begin
        stallLevel = `stallMemory;
    end
end

// Forwarding logic:
// If forward source is non-zero, it means that a value to be written is already in the pipeline
// which is either available or non-available.
// If the value to be read is not available (e.g. to be read from memory), we set valid flag to zero. This means
// a data hazard, and a bubble should be inserted to the pipeline.
// Otherwise the data is forwarded, and no stalling is created.

wire forwardValidE;
wire [4:0] forwardAddressE;
wire [31:0] forwardValueE;

// From ALU, in Memory
wire forwardValidM;
wire [4:0] forwardAddressM;
wire [31:0] forwardValueM;

// From Write
wire forwardValidW;
wire [4:0] forwardAddressW;
wire [31:0] forwardValueW;

// ======== Fetch Stage ========
reg F_jump;
reg [31:0] F_jumpAddr;
wire F_stall = stallLevel >= `stallFetch;


InstructionMemory F_im (
                      .clk(clk),
                      .reset(reset),
                      .absJump(F_jump),
                      .absJumpAddress(F_jumpAddr),
                      .pcStall(F_stall)
                  );

// ======== Decode Stage ========
wire D_stall = stallLevel >= `stallDecode;
reg D_last_bubble;
wire D_insert_bubble = D_last_bubble || D_data_waiting;
reg [31:0] D_currentInstruction;
reg [31:0] D_pc;

always @(posedge clk) begin
    if (reset) begin
        D_last_bubble <= 1;
    end
    else begin
        D_last_bubble <= 0;
    end
    if (!D_stall) begin
        D_currentInstruction <= F_im.instruction;
        D_pc <= F_im.pc;
    end
end

Controller D_ctrl(
               .instruction(D_currentInstruction),
               .reset(reset),
               .currentStage(`stageD),
               .bubble(D_last_bubble),
               .debugPC(D_pc)
           );

reg [4:0] grfWriteAddress;
reg [31:0] grfWriteData;
GeneralRegisterFile D_grf(
                        .clk(clk),
                        .reset(reset),
                        .writeData(grfWriteData),
                        .writeAddress(grfWriteAddress), // set to 0 if no write operation shall be performed

                        .readAddress1(D_ctrl.regRead1),
                        .readAddress2(D_ctrl.regRead2),
                        .debugPC(W_pc)
                    );

ForwardController D_regRead1_forward (
                      .request(D_ctrl.regRead1),
                      .original(D_grf.readOutput1),
                      .enabled(D_ctrl.regRead1Required),
                      .debugPC(D_pc),
                      .debugStage("D"),

                      .src1Valid(forwardValidE),
                      .src1Reg(forwardAddressE),
                      .src1Value(forwardValueE),
                      .src2Valid(forwardValidM),
                      .src2Reg(forwardAddressM),
                      .src2Value(forwardValueM),
                      .src3Valid(forwardValidW),
                      .src3Reg(forwardAddressW),
                      .src3Value(forwardValueW)
                  );

ForwardController D_regRead2_forward (
                      .request(D_ctrl.regRead2),
                      .original(D_grf.readOutput2),
                      .enabled(D_ctrl.regRead2Required),
                      .debugPC(D_pc),
                      .debugStage("D"),

                      .src1Valid(forwardValidE),
                      .src1Reg(forwardAddressE),
                      .src1Value(forwardValueE),
                      .src2Valid(forwardValidM),
                      .src2Reg(forwardAddressM),
                      .src2Value(forwardValueM),
                      .src3Valid(forwardValidW),
                      .src3Reg(forwardAddressW),
                      .src3Value(forwardValueW)
                  );

assign D_data_waiting = D_regRead1_forward.stallExec || D_regRead2_forward.stallExec;

Comparator cmp(
               .A(D_regRead1_forward.value),
               .B(D_regRead2_forward.value),
               .ctrl(D_ctrl.cmpCtrl)
           );
always @(*) begin
    F_jump = 0;
    F_jumpAddr = 0;
    if (D_ctrl.branch) begin
        F_jump = cmp.action;
        F_jumpAddr = D_pc + 4 + (D_ctrl.immediate << 2);
    end
    else if (D_ctrl.absJump) begin
        F_jump = 1;
        if (D_ctrl.absJumpLoc == `absJumpImmediate) begin
            F_jumpAddr = {D_pc[31:28], D_ctrl.immediate[25:0], 2'b00};
        end
        else begin
            F_jumpAddr = D_regRead1_forward.value;
        end
    end
end


// ======== Execution Stage ========

wire E_stall = stallLevel >= `stallExecution;
reg E_bubble;
wire E_insert_bubble = E_bubble || E_data_waiting;
reg [31:0] E_currentInstruction;
reg [31:0] E_pc;
reg [31:0] E_regRead1;
reg [31:0] E_regRead2;

reg E_regWriteDataValid;
reg [31:0] E_regWriteData;

assign forwardValidE = E_regWriteDataValid;
assign forwardAddressE = E_ctrl.destinationRegister;
assign forwardValueE = E_regWriteData;

always @(*) begin
    E_regWriteDataValid = 0;
    E_regWriteData = 'bx;
    case (E_ctrl.grfWriteSource)
        `grfWritePC: begin
            E_regWriteData = E_pc + 8;
            E_regWriteDataValid = 1;
        end
    endcase
end

always @(posedge clk) begin
    if (!E_stall) begin
        if (reset) begin
            E_bubble <= 1;
        end
        else begin
            E_bubble <= D_insert_bubble;
        end
        E_currentInstruction <= D_currentInstruction;
        E_pc <= D_pc;
        E_regRead1 <= D_regRead1_forward.value;
        E_regRead2 <= D_regRead2_forward.value;
    end
    else begin
        E_regRead1 <= E_regRead1_forward.value;
        E_regRead2 <= E_regRead2_forward.value;
    end
end

Controller E_ctrl(
               .instruction(E_currentInstruction),
               .reset(reset),
               .currentStage(`stageE),
               .bubble(E_bubble),
               .debugPC(E_pc)
           );

ForwardController E_regRead1_forward (
                      .request(E_ctrl.regRead1),
                      .original(E_regRead1),
                      .enabled(E_ctrl.regRead1Required),
                      .debugPC(E_pc),
                      .debugStage("E"),

                      .src1Valid(forwardValidM),
                      .src1Reg(forwardAddressM),
                      .src1Value(forwardValueM),

                      .src2Valid(forwardValidW),
                      .src2Reg(forwardAddressW),
                      .src2Value(forwardValueW),

                      .src3Reg(5'b0)
                  );

ForwardController E_regRead2_forward (
                      .request(E_ctrl.regRead2),
                      .original(E_regRead2),
                      .enabled(E_ctrl.regRead2Required),
                      .debugPC(E_pc),
                      .debugStage("E"),

                      .src1Valid(forwardValidM),
                      .src1Reg(forwardAddressM),
                      .src1Value(forwardValueM),

                      .src2Valid(forwardValidW),
                      .src2Reg(forwardAddressW),
                      .src2Value(forwardValueW),

                      .src3Reg(5'b0)
                  );

ArithmeticLogicUnit E_alu(
                        .ctrl(E_ctrl.aluCtrl),
                        .A(E_regRead1_forward.value),
                        .B(E_ctrl.aluSrc ? E_ctrl.immediate : E_regRead2_forward.value)
                    );

reg E_mul_collision;
assign E_data_waiting = E_regRead1_forward.stallExec || E_regRead2_forward.stallExec || E_mul_collision;
reg E_mulStart;

always @(*) begin
    E_mulStart = 0;
    E_mul_collision = 0;
    if (E_ctrl.mulEnable || E_ctrl.grfWriteSource == `grfWriteMul) begin
        if (E_mul.busy) begin
            E_mul_collision = 1;
        end
        else if (E_ctrl.mulEnable) begin
            E_mulStart = 1;
        end
    end
end

Multiplier E_mul(
               .ctrl(E_ctrl.mulCtrl),
               .start(!E_data_waiting && E_mulStart),
               .reset(reset),
               .clk(clk),
               .A(E_regRead1_forward.value),
               .B(E_ctrl.aluSrc ? E_ctrl.immediate : E_regRead2_forward.value)
           );

wire [31:0] E_mul_value = E_ctrl.mulOutputSel ? E_mul.HI : E_mul.LO;

// ======== Memory Stage ========

wire M_stall = stallLevel >= `stallMemory;
reg M_bubble;
wire M_insert_bubble = M_bubble || M_data_waiting;
reg [31:0] M_currentInstruction;
reg [31:0] M_pc;
reg [31:0] M_aluOutput;
reg [31:0] M_mulOutput;
reg [31:0] M_regRead1;
reg [31:0] M_regRead2;

reg M_lastWriteDataValid;
reg [31:0] M_lastWriteData;

reg M_regWriteDataValid;
reg [31:0] M_regWriteData;

always @(posedge clk) begin
    if (!M_stall) begin
        if (reset) begin
            M_bubble <= 1;
        end
        else begin
            M_bubble <= E_insert_bubble;
        end
        M_currentInstruction <= E_currentInstruction;
        M_pc <= E_pc;
        M_aluOutput <= E_alu.out;
        M_mulOutput <= E_mul_value;
        M_regRead1 <= E_regRead1_forward.value;
        M_regRead2 <= E_regRead2_forward.value;
        M_lastWriteDataValid <= E_regWriteDataValid;
        M_lastWriteData <= E_regWriteData;
    end
    else begin
        M_regRead1 <= M_regRead1_forward.value;
        M_regRead2 <= M_regRead2_forward.value;
    end
end

assign forwardAddressM = M_ctrl.destinationRegister;
assign forwardValueM = M_regWriteData;
assign forwardValidM = M_regWriteDataValid;
always @(*) begin
    if (M_lastWriteDataValid) begin
        M_regWriteData = M_lastWriteData;
        M_regWriteDataValid = 1;
    end
    else begin
        M_regWriteDataValid = 0;
        M_regWriteData = 'bx;
        case (M_ctrl.grfWriteSource)
            `grfWriteALU: begin
                M_regWriteData = M_aluOutput;
                M_regWriteDataValid = 1;
            end
            `grfWriteMul: begin
                M_regWriteData = M_mulOutput;
                M_regWriteDataValid = 1;
            end
        endcase
    end
end

Controller M_ctrl(
               .instruction(M_currentInstruction),
               .reset(reset),
               .currentStage(`stageM),
               .bubble(M_bubble),
               .debugPC(M_pc)
           );

ForwardController M_regRead1_forward (
                      .request(M_ctrl.regRead1),
                      .original(M_regRead1),
                      .enabled(M_ctrl.regRead1Required),
                      .debugPC(M_pc),
                      .debugStage("M"),

                      .src1Valid(forwardValidW),
                      .src1Reg(forwardAddressW),
                      .src1Value(forwardValueW),

                      .src2Reg(5'b0),
                      .src3Reg(5'b0)
                  );

ForwardController M_regRead2_forward (
                      .request(M_ctrl.regRead2),
                      .original(M_regRead2),
                      .enabled(M_ctrl.regRead2Required),
                      .debugPC(M_pc),
                      .debugStage("M"),

                      .src1Valid(forwardValidW),
                      .src1Reg(forwardAddressW),
                      .src1Value(forwardValueW),

                      .src2Reg(5'b0),
                      .src3Reg(5'b0)
                  );

assign M_data_waiting = M_regRead1_forward.stallExec || M_regRead2_forward.stallExec;

DataMemory M_dm(
               .clk(clk),
               .reset(reset),
               .debugPC(M_pc),
               .writeEnable(!M_data_waiting && M_ctrl.memStore),
               .widthCtrl(M_ctrl.memWidthCtrl),
               .extendCtrl(M_ctrl.memReadSignExtend),
               .address(M_aluOutput),
               .writeDataIn(M_regRead2_forward.value) // register@regRead2
           );


// ======== WriteBack Stage ========

reg [31:0] W_currentInstruction;
reg [31:0] W_memData;
reg [31:0] W_aluOutput;

reg W_lastWriteDataValid;
reg [31:0] W_lastWriteData;

reg W_bubble;
always @(posedge clk) begin
    if (reset) begin
        W_bubble <= 1;
    end
    else begin
        W_bubble <= M_insert_bubble;
    end
    W_currentInstruction <= M_currentInstruction;
    W_pc <= M_pc;
    W_aluOutput <= M_aluOutput;
    W_memData <= M_dm.readData;
    W_lastWriteData <= M_regWriteData;
    W_lastWriteDataValid <= M_regWriteDataValid;
end

Controller W_ctrl(
               .instruction(W_currentInstruction),
               .reset(reset),
               .currentStage(`stageW),
               .bubble(W_bubble),
               .debugPC(W_pc)
           );

assign forwardValidW = 1;
assign forwardAddressW = W_ctrl.destinationRegister;
assign forwardValueW = grfWriteData;

always @(*) begin
    grfWriteAddress = W_ctrl.destinationRegister;
    if (W_lastWriteDataValid) begin
        grfWriteData = W_lastWriteData;
    end
    else begin
        grfWriteData = 'bx;
        case (W_ctrl.grfWriteSource)
            `grfWriteMem: begin
                grfWriteData = W_memData;
            end
        endcase
    end
end

endmodule