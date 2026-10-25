// retro-z80: the computer, without board-specific parts (clocks, pads).
// After retro68k's retro68k.v.
//
// Version for ticket #11: tv80 at every CPUSPEED speed behind the bus
// interface, the scheduler and SRAM controller, the boot ROM, the system
// registers, USB serial, and the video unit (ticket #13: the 576p beam, the
// background colour, palettes and bitmap layers fetched through the
// scheduler; NLAYERS of them built). One DMA port stands in for the DMA users still
// to come, so tests can load the memory while the Z80 runs. Ticket #16 adds
// the interrupt controller, with VBLANK and SOFT as its sources so far.
// Ticket #17 adds the timers and watchdog, and the CPU's capture. Ticket
// #19 adds the input units (spec 12): the PS/2 keyboard and its Spectrum key
// mapper, the membrane keyboard and port 0xFE, the joysticks and Kempston.
// Ticket #21 adds port 0xFE writes: the border (video.v) and the beeper,
// out through the sigma-delta audio streams (audio.v).
module retroz80 #(
    parameter ROM_INIT = "boot.hex",
    parameter [5:0] CHIPMB = 6'd4,
    parameter NLAYERS = 1              // video layers built, 1-3 (spec 4)
) (
    input  wire        clk,            // 100 MHz system clock
    input  wire        por,            // power-on reset; last seen high on a slot boundary
    input  wire        btn_reset_n,    // debounced
    input  wire [1:0]  buttons,        // MULTIFACE (0), DIVMMC (1), 1 = pressed

    // SRAM (before the DDR output registers)
    output wire [20:0] sram_a,
    output wire        sram_ce_n, sram_ub_n, sram_lb_n,
    output wire        sram_oe_n_r, sram_oe_n_f,
    output wire        sram_we_n_r, sram_we_n_f,
    output wire [15:0] sram_dq_o,
    output wire        sram_dq_t_r, sram_dq_t_f,
    input  wire [15:0] sram_dq_i,

    // FT232H
    input  wire        ft_rxf_n, ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output wire [7:0]  ft_d_o,
    output wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n,

    // Video (spec 4): the pixel clock and the picture, before the HDMI and
    // VGA output stages (board parts)
    input  wire        clk_pix,        // 27 MHz
    input  wire        clk_pix5,       // 135 MHz, edges lined up with clk_pix's
    output wire [23:0] vid_rgb,        // RRGGBB
    output wire        vid_hsync, vid_vsync, vid_de,

    // Input (spec 12): open-drain lines say when to pull low
    input  wire        ps2_clk_i, ps2_data_i,
    output wire        ps2_clk_low, ps2_data_low,
    output wire [7:0]  keyb_row_low,   // membrane row r driven low
    input  wire [6:0]  keyb_col_i,     // membrane columns, pulled up
    input  wire [5:0]  joy_pin_n,      // joystick pins 9, 6, 4, 3, 2, 1 (bits 5-0)
    output wire        joy_sel,        // joystick multiplexer: 0 port 1, 1 port 2
    output wire        joy_p7,         // joystick pin 7, the Mega Drive select

    // Audio (spec 7, section 10.2): sigma-delta streams, before the pads
    output wire        audio_l, audio_r, audio_m,

    // DMA port (tests; later the DMA users)
    input  wire        dma_req, dma_we,
    input  wire [21:1] dma_addr,
    input  wire [15:0] dma_wdata,
    input  wire [1:0]  dma_be,
    output wire        dma_ack, dma_rvalid,
    output wire [15:0] dma_rdata,

    // Debug
    output wire [3:0]  dbg_sc
);
    // ---------------------------------------------------------------- timebase
    wire [3:0] sc;
    timebase tb0 (.clk(clk), .rst(por), .sc(sc));
    assign dbg_sc = sc;

    reg [6:0] us_div;
    wire      us_tick = (us_div == 7'd99);
    always @(posedge clk) us_div <= (por || us_tick) ? 7'd0 : us_div + 1'b1;

    // ---------------------------------------------------------------- reset (spec 7, section 3)
    wire soft_reset, cmd_break, cmd_reset, cmd_upload;
    reg  [1:0] btn_s;
    always @(posedge clk) btn_s <= {btn_s[0], btn_reset_n};

    wire wd_reset;                     // from the watchdog (timers.v)
    wire rst_req = !btn_s[1] || soft_reset || cmd_reset || cmd_upload || wd_reset;
    reg  [8:0] rst_cnt;
    reg        sys_rst;
    reg  [7:0] resetwhy;

    always @(posedge clk) begin
        if (por) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            resetwhy <= 8'h01;                          // POWER
        end else if (rst_req && !sys_rst) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            // Exactly one bit (spec 7, section 3.1): UPLOAD, USB, WATCHDOG, SOFTWARE, BUTTON
            resetwhy <= cmd_upload ? 8'h20 : cmd_reset ? 8'h10 : wd_reset ? 8'h02 :
                        soft_reset ? 8'h08 : 8'h04;
        end else if (sys_rst) begin
            // Hold reset for 5.12 us, and end it on a slot boundary
            if (rst_cnt != 9'd511) rst_cnt <= rst_cnt + 1'b1;
            else if (sc == 4'd9)   sys_rst <= 1'b0;
        end
    end

    // The Z80 leaves reset at slot edge 5, so that its first cen edge, which
    // starts its first T1, is slot edge 0 (spec 1, section 9)
    reg cpu_rst_n;
    always @(posedge clk)
        if (por)              cpu_rst_n <= 1'b0;
        else if (sc == 4'd4)  cpu_rst_n <= !sys_rst;

    // ---------------------------------------------------------------- CPU (spec 1)
    wire [15:0] c_a;
    wire [7:0]  c_dout, c_di;
    wire [6:0]  c_mcycle, c_tstate;
    wire        c_m1_n, c_mreq_n, c_iorq_n, c_rd_n, c_wr_n, c_rfsh_n, c_halt_n, c_busak_n;
    wire        c_iorq, c_no_read, c_write, c_intcycle_n;
    wire        int_n;                 // from the interrupt controller

    // A T-state every 5n clocks on slot edges 0 and 5, or every 28 clocks,
    // as CPUSPEED says (spec 1, section 3; spec 7, section 6.1)
    wire [3:0] cpuspeed;
    wire       cen;
    cpu_cen cdiv (.clk(clk), .rst(!cpu_rst_n), .sc(sc), .cpuspeed(cpuspeed), .t1(c_tstate[1]), .cen(cen));

    z80_cpu cpu (
        .clk(clk), .cen(cen), .reset_n(cpu_rst_n),
        .wait_n(1'b1), .int_n(int_n), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(c_m1_n), .mreq_n(c_mreq_n), .iorq_n(c_iorq_n), .rd_n(c_rd_n), .wr_n(c_wr_n),
        .rfsh_n(c_rfsh_n), .halt_n(c_halt_n), .busak_n(c_busak_n),
        .A(c_a), .di(c_di), .dout(c_dout),
        .mcycle(c_mcycle), .tstate(c_tstate), .iorq(c_iorq), .no_read(c_no_read),
        .write(c_write), .intcycle_n(c_intcycle_n)
    );

    // ---------------------------------------------------------------- bus interface
    wire [2:0]  mmu_win;
    wire [9:0]  mmu_rpage, mmu_wpage;
    wire        cpu_req, cpu_we, cpu_ack, cpu_rvalid;
    wire [21:1] cpu_addr;
    wire [15:0] cpu_wdata, mem_rdata;
    wire [1:0]  cpu_be;
    wire        romwe, rom_en;
    wire [1:0]  rom_we;
    wire [14:1] rom_addr;
    wire [15:0] rom_wdata, rom_rdata;
    wire [12:0] rb_addr;
    wire [7:0]  rb_hi, rb_wdata, rd_sys, rd_ser, rd_mmu, rd_vid, rd_int;
    wire [7:0]  rd_tmr;                // timers (#17), and their capture path
    wire [7:0]  rd_kb, rd_key, rd_joy; // input (#19)
    wire        hit_kb, hit_key, hit_joy;
    wire        hit_tmr, cap_tmr, frame_tick, line_tick;
    wire [31:0] cd_tmr;
    wire        rb_rd, rb_wr, hit_sys, hit_ser, hit_mmu, hit_vid, hit_int;
    wire        late;
    wire        int_vreq, int_ack;
    wire [7:0]  int_vec;

    bus_if bif (
        .clk(clk), .rst(!cpu_rst_n), .cen(cen),
        .A(c_a), .dout(c_dout), .mcycle(c_mcycle), .tstate(c_tstate), .iorq(c_iorq),
        .no_read(c_no_read), .write(c_write), .intcycle_n(c_intcycle_n),
        .m1_n(c_m1_n), .iorq_n(c_iorq_n), .rd_n(c_rd_n), .wr_n(c_wr_n), .di(c_di),
        .mmu_win(mmu_win), .mmu_rpage(mmu_rpage), .mmu_wpage(mmu_wpage),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .cpu_be(cpu_be), .cpu_ack(cpu_ack), .cpu_rvalid(cpu_rvalid), .mem_rdata(mem_rdata),
        .romwe(romwe), .rom_en(rom_en), .rom_we(rom_we), .rom_addr(rom_addr),
        .rom_wdata(rom_wdata), .rom_rdata(rom_rdata),
        .rb_addr(rb_addr), .rb_hi(rb_hi), .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_sys | rd_ser | rd_mmu | rd_vid | rd_int | rd_tmr | rd_kb | rd_key | rd_joy),
        .rb_hit(hit_sys | hit_ser | hit_mmu | hit_vid | hit_int | hit_tmr | hit_kb | hit_key | hit_joy),
        .rb_cdata(cd_tmr), .rb_cap(cap_tmr),
        .int_vreq(int_vreq), .int_vec(int_vec), .int_ack(int_ack),
        .late(late)
    );

    // ---------------------------------------------------------------- MMU (spec 2, section 9)
    mmu mmu0 (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_mmu), .rb_hit(hit_mmu),
        .win(mmu_win), .rpage(mmu_rpage), .wpage(mmu_wpage)
    );

    // ---------------------------------------------------------------- memory (spec 2)
    wire        go, go_we, m_start, m_rvalid;
    wire [21:1] go_addr;
    wire [15:0] go_wdata;
    wire [1:0]  go_be;
    wire [2:0]  go_tag, m_cycle, m_rtag;
    wire        bpl_req, bpl_urgent, bpl_ack, bpl_rvalid;
    wire [21:1] bpl_addr;
    wire [9:0]  bpl_deadline;

    // The scheduler and the SRAM controller are reset only at power-on, so
    // a memory cycle in flight when another reset comes is completed (the
    // SRAM keeps its contents across a reset, spec 7, section 3.2)
    dmac sched (
        .clk(clk), .rst(por), .start_next(m_start), .next_cycle(m_cycle),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .cpu_be(cpu_be), .cpu_ack(cpu_ack), .cpu_rvalid(cpu_rvalid),
        .bpl_req(bpl_req), .bpl_addr(bpl_addr), .bpl_deadline(bpl_deadline), .bpl_urgent(bpl_urgent),
        .bpl_ack(bpl_ack), .bpl_rvalid(bpl_rvalid),
        .spr_req(1'b0), .spr_addr(21'd0), .spr_deadline(10'd0), .spr_urgent(1'b0), .spr_ack(), .spr_rvalid(),
        .aud_req(1'b0), .aud_addr(21'd0), .aud_ack(), .aud_rvalid(),
        .cop_req(1'b0), .cop_addr(21'd0), .cop_pri(2'd0), .cop_ack(), .cop_rvalid(),
        .blt_req(1'b0), .blt_we(1'b0), .blt_addr(21'd0), .blt_wdata(16'd0), .blt_be(2'b00),
        .blt_ack(), .blt_rvalid(),
        .port_req(dma_req), .port_we(dma_we), .port_addr(dma_addr), .port_wdata(dma_wdata),
        .port_be(dma_be), .port_ack(dma_ack), .port_rvalid(dma_rvalid),
        .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be),
        .go_tag(go_tag), .rvalid(m_rvalid), .rtag(m_rtag)
    );
    assign dma_rdata = mem_rdata;

    // A 2 MB build ignores physical address bit 21, for every master, so
    // 0x200000-0x3FFFFF (MMU pages 0x100-0x1FF) mirrors the bottom half
    // (spec 2, section 11). SYSCFG.CHIPMB reports the build's size.
    wire [21:1] sram_addr = {go_addr[21] && CHIPMB != 6'd2, go_addr[20:1]};

    sram_ctl mem (
        .clk(clk), .rst(por), .sc(sc),
        .go(go), .go_we(go_we), .go_addr(sram_addr), .go_wdata(go_wdata), .go_be(go_be),
        .go_tag(go_tag), .start_next(m_start), .next_cycle(m_cycle),
        .rvalid(m_rvalid), .rtag(m_rtag), .rdata(mem_rdata),
        .sram_a(sram_a), .sram_ce_n(sram_ce_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n),
        .sram_oe_n_r(sram_oe_n_r), .sram_oe_n_f(sram_oe_n_f),
        .sram_we_n_r(sram_we_n_r), .sram_we_n_f(sram_we_n_f),
        .sram_dq_o(sram_dq_o), .sram_dq_t_r(sram_dq_t_r), .sram_dq_t_f(sram_dq_t_f),
        .sram_dq_i(sram_dq_i)
    );

    bootrom #(.INIT(ROM_INIT)) rom (
        .clk(clk), .en(rom_en), .we(rom_we), .addr(rom_addr), .wdata(rom_wdata), .rdata(rom_rdata)
    );

    // ---------------------------------------------------------------- system registers (spec 7)
    sysregs #(.CHIPMB(CHIPMB)) sys (
        .clk(clk), .rst(sys_rst), .por(por),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_sys), .rb_hit(hit_sys),
        .resetwhy(resetwhy), .buttons(buttons),
        .romwe(romwe), .soft_reset(soft_reset), .cpuspeed(cpuspeed)
    );

    // ---------------------------------------------------------------- USB serial (spec 10)
    serial ser (
        .clk(clk), .rst(sys_rst), .por(por), .us_tick(us_tick),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_ser), .rb_hit(hit_ser),
        .irq(), .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .p_rxv(), .p_rxd(), .p_rxpop(1'b0), .p_txr(), .p_txpush(1'b0), .p_txd(8'd0),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
    );

    // ---------------------------------------------------------------- interrupts (spec 8)
    // Sources so far: VBLANK (0), TIMER0-3 (11-14), KEYB (17) and SOFT (18,
    // inside the controller). The
    // other lines are tied off until their units come; the NMI is not
    // connected to the Z80 yet (it comes with the NMI paging, spec 1,
    // section 8.2), so its inputs are tied off too.
    wire        irq_vid;
    wire [3:0]  irq_tmr;               // TIMER0-3: sources 11-14
    wire        irq_kb;                // KEYB: source 17
    wire [20:0] int_req = {3'd0, irq_kb, 2'd0, irq_tmr, 10'd0, irq_vid};

    intc ic (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_int), .rb_hit(hit_int),
        .req(int_req), .int_n(int_n), .vreq(int_vreq), .vector(int_vec), .int_ack(int_ack),
        .nmi_button(1'b0), .nmi_usb(1'b0), .nmi_ack(1'b0), .nmi_n()
    );

    // ---------------------------------------------------------------- video (spec 4)
    video #(.NL(NLAYERS)) vid (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_vid), .rb_hit(hit_vid),
        .frame_tick(frame_tick), .line_tick(line_tick), .irq(irq_vid),
        .disp_req(bpl_req), .disp_urgent(bpl_urgent), .disp_deadline(bpl_deadline), .disp_addr(bpl_addr),
        .disp_ack(bpl_ack), .disp_rvalid(bpl_rvalid), .disp_rdata(mem_rdata),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5),
        .rgb(vid_rgb), .hsync(vid_hsync), .vsync(vid_vsync), .de(vid_de)
    );

    // ---------------------------------------------------------------- timers and watchdog (spec 9)
    // Line and frame ticks from the display beam (video.v); the DMA start
    // lines wait for the DMA engine (spec 14). The capture path (rb_cdata,
    // rb_cap) goes to the bus interface, the CPU's one capture.
    timers tmr (
        .clk(clk), .por(por), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_tmr), .rb_hit(hit_tmr), .rb_cdata(cd_tmr), .rb_cap(cap_tmr),
        .us_tick(us_tick), .line_tick(line_tick), .frame_tick(frame_tick),
        .irq(irq_tmr), .dma_start(), .wd_reset(wd_reset)
    );

    // ---------------------------------------------------------------- input (spec 12)
    // The PS/2 keyboard, its mapper onto the Spectrum keys, the membrane
    // and port 0xFE, the joysticks and Kempston port 0x1F
    wire        ps2map_en, kb_rx_stb, kb_rx_on;
    wire [7:0]  kb_rx_byte;
    wire [39:0] ps2_keys;

    ps2kb kb (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_kb), .rb_hit(hit_kb),
        .ps2_clk_i(ps2_clk_i), .ps2_data_i(ps2_data_i),
        .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .map_en(ps2map_en), .rx_stb(kb_rx_stb), .rx_byte(kb_rx_byte), .rx_on(kb_rx_on),
        .irq(irq_kb)
    );

    ps2map kmap (
        .clk(clk), .clr(sys_rst || !kb_rx_on || !ps2map_en),
        .stb(kb_rx_stb), .byte_in(kb_rx_byte), .keys(ps2_keys)
    );

    keys key (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_hi(rb_hi), .rb_wdata(rb_wdata),
        .rb_rdata(rd_key), .rb_hit(hit_key),
        .row_low(keyb_row_low), .col_i(keyb_col_i),
        .ps2_keys(ps2_keys), .ps2map_en(ps2map_en)
    );

    joy joys (
        .clk(clk), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_joy), .rb_hit(hit_joy),
        .pin_n(joy_pin_n), .joysel(joy_sel), .sel_o(joy_p7)
    );

    // ---------------------------------------------------------------- audio (spec 7, section 10.2)
    // The beeper (port 0xFE bit 4) at a quarter of full scale, through
    // three sigma-delta modulators: left, right and mono
    audio aud (
        .clk(clk), .rst(sys_rst),
        .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .dac_l(audio_l), .dac_r(audio_r), .dac_m(audio_m)
    );
endmodule
