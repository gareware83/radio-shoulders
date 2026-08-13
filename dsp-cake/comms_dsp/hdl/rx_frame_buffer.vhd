library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.pkg.all;

------------------------------------------------------------------------------
-- RX frame buffer and AXI-Stream packer. Payload bytes in, 32-bit stream out
-- to the DMA S2MM channel, one AXI-Stream packet per frame.
--
-- STORE-AND-FORWARD, NOT CUT-THROUGH. The frame is held here until the CRC
-- verdict arrives, and only released to the DMA if it passed. This is the main
-- design decision in this module and it is worth being explicit about:
--
--   Streaming payload bytes to DDR as they arrive would be simpler in hardware
--   and would need no buffer at all - but the CRC only arrives AFTER the
--   payload, so userspace would find bytes in its buffer with no way to know
--   whether they were good until a status register told it separately. Every
--   reader would have to implement that handshake correctly, and a torn or
--   mis-ordered read of the status register silently yields corrupt data
--   treated as valid.
--
--   Storing first means a completed DMA transfer IS a valid frame. Userspace
--   reads the buffer and is done. The cost is 256 bytes of block RAM and a
--   hard 255-byte frame ceiling, which the frame format already imposes.
--
-- Each packet is prefixed with one METADATA WORD so the buffer is
-- self-describing and userspace needs no side-channel:
--
--   bits  7:0   payload length in bytes
--   bits 11:8   frame type
--   bits 15:12  sequence number
--   bits 31:16  frame counter, low 16 bits (gap detection)
--
-- Payload bytes are packed little-endian within each word - byte 0 in bits
-- 7:0 - so an ARM memcpy of the DMA buffer gives back the wire order.
-- tkeep marks the valid bytes of a partial final word.
--
-- BACKPRESSURE: if the PS has not armed an S2MM transfer, tready stays low and
-- readout stalls here rather than dropping bytes. A frame arriving while the
-- previous one is still draining is dropped and flagged in overflow - a single
-- buffer cannot hold both. If that turns out to matter, this becomes a small
-- FIFO of frames rather than one buffer.
--
-- Not simulated.
------------------------------------------------------------------------------
entity rx_frame_buffer is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        clr_stats   : in  std_logic;

        -- from frame_sync
        byte_valid  : in  std_logic;
        byte_data   : in  std_logic_vector(7 downto 0);
        frame_start : in  std_logic;
        frame_done  : in  std_logic;
        frame_ok    : in  std_logic;
        frame_len   : in  unsigned(7 downto 0);
        frame_type  : in  std_logic_vector(3 downto 0);
        frame_seq   : in  std_logic_vector(3 downto 0);

        -- AXI-Stream master -> DMA S2MM
        m_tdata     : out std_logic_vector(31 downto 0);
        m_tkeep     : out std_logic_vector(3 downto 0);
        m_tlast     : out std_logic;
        m_tvalid    : out std_logic;
        m_tready    : in  std_logic;

        -- status
        frame_count : out unsigned(15 downto 0);
        err_count   : out unsigned(15 downto 0);
        overflow    : out std_logic;
        rx_len      : out unsigned(7 downto 0)   -- length of last good frame
    );
end rx_frame_buffer;

architecture rtl of rx_frame_buffer is

    type ram_t is array (0 to C_MAX_PAYLOAD_WORDS-1)
        of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    -- write side
    signal wr_byte  : unsigned(7 downto 0) := (others => '0');
    signal word_acc : std_logic_vector(31 downto 0) := (others => '0');

    -- read side
    type rd_state_t is (RD_IDLE, RD_META, RD_DATA);
    signal rd_state : rd_state_t := RD_IDLE;
    signal rd_addr  : unsigned(6 downto 0) := (others => '0');
    signal rd_words : unsigned(6 downto 0) := (others => '0');  -- ceil(len/4)
    signal rd_len   : unsigned(7 downto 0) := (others => '0');
    signal meta     : std_logic_vector(31 downto 0) := (others => '0');

    signal frames   : unsigned(15 downto 0) := (others => '0');
    signal errs     : unsigned(15 downto 0) := (others => '0');
    signal ovf      : std_logic := '0';

    -- valid-byte mask for the final word
    function last_keep (len : unsigned(7 downto 0)) return std_logic_vector is
    begin
        case len(1 downto 0) is
            when "01"   => return "0001";
            when "10"   => return "0011";
            when "11"   => return "0111";
            when others => return "1111";   -- exact multiple of 4
        end case;
    end function;

begin

    frame_count <= frames;
    err_count   <= errs;
    overflow    <= ovf;
    rx_len      <= rd_len;

    --------------------------------------------------------------------------
    -- Write side: pack bytes into words, store, and act on the CRC verdict.
    --------------------------------------------------------------------------
    wr_proc : process (clk)
        variable nwords : unsigned(6 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_byte  <= (others => '0');
                word_acc <= (others => '0');
                frames   <= (others => '0');
                errs     <= (others => '0');
                ovf      <= '0';
                rd_state <= RD_IDLE;
                rd_addr  <= (others => '0');
                rd_words <= (others => '0');
                rd_len   <= (others => '0');
                meta     <= (others => '0');
            else
                if clr_stats = '1' then
                    frames <= (others => '0');
                    errs   <= (others => '0');
                    ovf    <= '0';
                end if;

                if frame_start = '1' then
                    if rd_state /= RD_IDLE then
                        -- previous frame still draining to the DMA
                        ovf <= '1';
                    end if;
                    wr_byte <= (others => '0');
                end if;

                ------------------------------------------------------------
                -- byte -> word packing, little-endian within the word
                ------------------------------------------------------------
                if byte_valid = '1' then
                    case wr_byte(1 downto 0) is
                        when "00"   => word_acc(7  downto  0) <= byte_data;
                        when "01"   => word_acc(15 downto  8) <= byte_data;
                        when "10"   => word_acc(23 downto 16) <= byte_data;
                        when others =>
                            -- Fourth byte completes the word. word_acc's lower
                            -- three bytes were written on previous cycles and
                            -- are stable; only the top byte comes from this one.
                            ram(to_integer(wr_byte(7 downto 2)))
                                <= byte_data & word_acc(23 downto 0);
                    end case;
                    wr_byte <= wr_byte + 1;
                end if;

                ------------------------------------------------------------
                -- CRC verdict: release or discard
                ------------------------------------------------------------
                if frame_done = '1' then
                    if frame_ok = '1' then
                        frames <= frames + 1;

                        -- Flush a partial final word. Its unused upper bytes
                        -- are stale, which is why tkeep matters below.
                        if wr_byte(1 downto 0) /= "00" then
                            ram(to_integer(wr_byte(7 downto 2))) <= word_acc;
                        end if;

                        if frame_len(1 downto 0) = "00" then
                            nwords := resize(frame_len(7 downto 2), 7);
                        else
                            nwords := resize(frame_len(7 downto 2), 7) + 1;
                        end if;

                        if rd_state = RD_IDLE then
                            rd_len   <= frame_len;
                            rd_words <= nwords;
                            rd_addr  <= (others => '0');
                            meta     <= std_logic_vector(frames + 1) &
                                        frame_seq & frame_type &
                                        std_logic_vector(frame_len);
                            rd_state <= RD_META;
                        else
                            ovf <= '1';
                        end if;
                    else
                        errs <= errs + 1;
                    end if;
                end if;

                ------------------------------------------------------------
                -- readout, advanced only when the DMA accepts a beat
                ------------------------------------------------------------
                case rd_state is
                    when RD_META =>
                        if m_tready = '1' then
                            if rd_words = 0 then
                                rd_state <= RD_IDLE;   -- zero-length payload
                            else
                                rd_state <= RD_DATA;
                            end if;
                        end if;

                    when RD_DATA =>
                        if m_tready = '1' then
                            if rd_addr = rd_words - 1 then
                                rd_state <= RD_IDLE;
                            else
                                rd_addr <= rd_addr + 1;
                            end if;
                        end if;

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Stream output. Asynchronous RAM read - at 64 words this infers
    -- distributed RAM, which sidesteps the extra pipeline stage a block RAM
    -- read would need to interact correctly with tready backpressure.
    --------------------------------------------------------------------------
    m_tvalid <= '1' when rd_state /= RD_IDLE else '0';

    m_tdata  <= meta                              when rd_state = RD_META else
                ram(to_integer(rd_addr))          when rd_state = RD_DATA else
                (others => '0');

    m_tkeep  <= "1111" when rd_state = RD_META else
                last_keep(rd_len) when (rd_state = RD_DATA and rd_addr = rd_words - 1) else
                "1111";

    m_tlast  <= '1' when (rd_state = RD_META and rd_words = 0) else
                '1' when (rd_state = RD_DATA and rd_addr = rd_words - 1) else
                '0';

end rtl;
