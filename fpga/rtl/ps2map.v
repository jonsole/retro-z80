// PS/2 keys onto the Spectrum matrix (spec 12, section 8.3): the mapper
// watches the bytes the PS/2 receiver takes (ps2kb.v's rx_stb, rx_byte),
// before the FIFO, follows the E0 prefix and the F0 release code, and keeps
// a held bit for each of the 70 mapped keys. A Spectrum key shows as
// pressed while any held PS/2 key gives it.
//
// The Spectrum keys are numbered k = 5 x row + column, as port 0xFE shows
// them (spec 12, section 8.1): row 0 CAPS SHIFT Z X C V (0-4) ... row 7
// SPACE SYMBOL SHIFT M N B (35-39). keys[k] = 1: pressed.
//
// Pause (E1 and the 7 bytes after it) and every key not in the table map to
// nothing; the keyboard's fake shifts (E0 12, E0 59) are not in the table.
// The held bits are cleared by clr (reset, PS2MAP = 0, the receiver
// stopped) and when the keyboard sends AA (self-test passed).
module ps2map (
    input  wire        clk,
    input  wire        clr,
    input  wire        stb,
    input  wire [7:0]  byte_in,
    output wire [39:0] keys
);
    localparam NK = 70;
    localparam [5:0] NONE = 6'd63;
    localparam [5:0] CS = 6'd0, SS = 6'd36;

    // The table: {E0, code} -> mapped key number, 0-69, or 127
    function [6:0] kidx(input [8:0] c);
        case (c)
            // letters A-Z
            9'h01C: kidx = 7'd0;   9'h032: kidx = 7'd1;   9'h021: kidx = 7'd2;   9'h023: kidx = 7'd3;
            9'h024: kidx = 7'd4;   9'h02B: kidx = 7'd5;   9'h034: kidx = 7'd6;   9'h033: kidx = 7'd7;
            9'h043: kidx = 7'd8;   9'h03B: kidx = 7'd9;   9'h042: kidx = 7'd10;  9'h04B: kidx = 7'd11;
            9'h03A: kidx = 7'd12;  9'h031: kidx = 7'd13;  9'h044: kidx = 7'd14;  9'h04D: kidx = 7'd15;
            9'h015: kidx = 7'd16;  9'h02D: kidx = 7'd17;  9'h01B: kidx = 7'd18;  9'h02C: kidx = 7'd19;
            9'h03C: kidx = 7'd20;  9'h02A: kidx = 7'd21;  9'h01D: kidx = 7'd22;  9'h022: kidx = 7'd23;
            9'h035: kidx = 7'd24;  9'h01A: kidx = 7'd25;
            // 1-0 on the main row
            9'h016: kidx = 7'd26;  9'h01E: kidx = 7'd27;  9'h026: kidx = 7'd28;  9'h025: kidx = 7'd29;
            9'h02E: kidx = 7'd30;  9'h036: kidx = 7'd31;  9'h03D: kidx = 7'd32;  9'h03E: kidx = 7'd33;
            9'h046: kidx = 7'd34;  9'h045: kidx = 7'd35;
            // keypad 0-9 (no E0)
            9'h070: kidx = 7'd36;  9'h069: kidx = 7'd37;  9'h072: kidx = 7'd38;  9'h07A: kidx = 7'd39;
            9'h06B: kidx = 7'd40;  9'h073: kidx = 7'd41;  9'h074: kidx = 7'd42;  9'h06C: kidx = 7'd43;
            9'h075: kidx = 7'd44;  9'h07D: kidx = 7'd45;
            // Enter, keypad Enter, Space, the shifts, Ctrl and Alt
            9'h05A: kidx = 7'd46;  9'h15A: kidx = 7'd47;  9'h029: kidx = 7'd48;
            9'h012: kidx = 7'd49;  9'h059: kidx = 7'd50;
            9'h014: kidx = 7'd51;  9'h114: kidx = 7'd52;  9'h011: kidx = 7'd53;  9'h111: kidx = 7'd54;
            // Backspace, the cursor keys, Escape, Caps Lock, Tab
            9'h066: kidx = 7'd55;
            9'h16B: kidx = 7'd56;  9'h172: kidx = 7'd57;  9'h175: kidx = 7'd58;  9'h174: kidx = 7'd59;
            9'h076: kidx = 7'd60;  9'h058: kidx = 7'd61;  9'h00D: kidx = 7'd62;
            // , . ; ' / - =
            9'h041: kidx = 7'd63;  9'h049: kidx = 7'd64;  9'h04C: kidx = 7'd65;  9'h052: kidx = 7'd66;
            9'h04A: kidx = 7'd67;  9'h04E: kidx = 7'd68;  9'h055: kidx = 7'd69;
            default: kidx = 7'd127;
        endcase
    endfunction

    // Mapped key i -> its Spectrum key(s): {second, first}, NONE for no second
    function [11:0] spk(input integer i);
        case (i)
            // A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
            0:  spk = {NONE, 6'd5};   1:  spk = {NONE, 6'd39};  2:  spk = {NONE, 6'd3};
            3:  spk = {NONE, 6'd7};   4:  spk = {NONE, 6'd12};  5:  spk = {NONE, 6'd8};
            6:  spk = {NONE, 6'd9};   7:  spk = {NONE, 6'd34};  8:  spk = {NONE, 6'd27};
            9:  spk = {NONE, 6'd33};  10: spk = {NONE, 6'd32};  11: spk = {NONE, 6'd31};
            12: spk = {NONE, 6'd37};  13: spk = {NONE, 6'd38};  14: spk = {NONE, 6'd26};
            15: spk = {NONE, 6'd25};  16: spk = {NONE, 6'd10};  17: spk = {NONE, 6'd13};
            18: spk = {NONE, 6'd6};   19: spk = {NONE, 6'd14};  20: spk = {NONE, 6'd28};
            21: spk = {NONE, 6'd4};   22: spk = {NONE, 6'd11};  23: spk = {NONE, 6'd2};
            24: spk = {NONE, 6'd29};  25: spk = {NONE, 6'd1};
            // 1 2 3 4 5 6 7 8 9 0, on the main row and on the keypad
            26, 37: spk = {NONE, 6'd15};  27, 38: spk = {NONE, 6'd16};  28, 39: spk = {NONE, 6'd17};
            29, 40: spk = {NONE, 6'd18};  30, 41: spk = {NONE, 6'd19};  31, 42: spk = {NONE, 6'd24};
            32, 43: spk = {NONE, 6'd23};  33, 44: spk = {NONE, 6'd22};  34, 45: spk = {NONE, 6'd21};
            35, 36: spk = {NONE, 6'd20};
            46, 47: spk = {NONE, 6'd30};                    // ENTER
            48:     spk = {NONE, 6'd35};                    // SPACE
            49, 50: spk = {NONE, CS};
            51, 52, 53, 54: spk = {NONE, SS};
            55: spk = {6'd20, CS};                          // DELETE: CAPS SHIFT + 0
            56: spk = {6'd19, CS};                          // cursor left, down, up, right: CAPS SHIFT + 5-8
            57: spk = {6'd24, CS};
            58: spk = {6'd23, CS};
            59: spk = {6'd22, CS};
            60: spk = {6'd35, CS};                          // BREAK: CAPS SHIFT + SPACE
            61: spk = {6'd16, CS};                          // CAPS LOCK: CAPS SHIFT + 2
            62: spk = {SS, CS};                             // EXTEND MODE
            63: spk = {6'd38, SS};                          // , = SYMBOL SHIFT + N
            64: spk = {6'd37, SS};                          // . = M
            65: spk = {6'd26, SS};                          // ; = O
            66: spk = {6'd23, SS};                          // ' = 7
            67: spk = {6'd4,  SS};                          // / = V
            68: spk = {6'd33, SS};                          // - = J
            69: spk = {6'd31, SS};                          // = = L
            default: spk = {NONE, NONE};
        endcase
    endfunction

    reg [NK-1:0] held;
    reg          e0, f0;
    reg  [2:0]   e1n;                  // Pause bytes still to skip
    wire [6:0]   ix = kidx({e0, byte_in});

    always @(posedge clk)
        if (clr) begin
            held <= {NK{1'b0}};
            e0 <= 1'b0; f0 <= 1'b0; e1n <= 3'd0;
        end else if (stb) begin
            if (e1n != 3'd0)            e1n <= e1n - 1'b1;
            else if (byte_in == 8'hE1)  e1n <= 3'd7;
            else if (byte_in == 8'hAA)  begin held <= {NK{1'b0}}; e0 <= 1'b0; f0 <= 1'b0; end
            else if (byte_in == 8'hE0)  e0 <= 1'b1;
            else if (byte_in == 8'hF0)  f0 <= 1'b1;
            else begin
                if (ix != 7'd127) held[ix[6:0]] <= !f0;
                e0 <= 1'b0;
                f0 <= 1'b0;
            end
        end

    // Mapped keys that give Spectrum key k: a constant, so each Spectrum
    // key is a fixed OR of held bits
    function [NK-1:0] mask(input integer k);
        integer i;
        reg [11:0] s;
        begin
            for (i = 0; i < NK; i = i + 1) begin
                s = spk(i);
                mask[i] = (s[5:0] == k[5:0]) || (s[11:6] == k[5:0]);
            end
        end
    endfunction

    genvar k;
    generate for (k = 0; k < 40; k = k + 1) begin : sk
        localparam [NK-1:0] M = mask(k);
        assign keys[k] = |(held & M);
    end endgenerate
endmodule
