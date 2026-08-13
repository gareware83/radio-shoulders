library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.pkg.all;

------------------------------------------------------------------------------
-- Frame recovery: sliced bit pairs in, payload bytes + CRC verdict out.
--
--   | PREAMBLE 32 | SYNC 32 | HEADER 16 | PAYLOAD 0-255B | CRC16 |
--
-- The preamble is not searched for. It exists to give the carrier and timing
-- loops something to converge on before anything that matters arrives - by the
-- time the sync word appears the loops should be settled. Hunting for it as
-- well would buy nothing: 0xAAAAAAAA is a repeating pattern with no unique
-- alignment, which is exactly what makes it good for acquisition and useless
-- for framing.
--
-- SYNC WORD SEARCH IS BIT-CONTINUOUS. There is no symbol-boundary ambiguity to
-- resolve - every symbol contributes exactly 2 bits in a fixed order - so the
-- shift register advances 2 bits per symbol and is compared once per symbol.
--
-- PHASE AMBIGUITY is resolved here, because this is the first point in the
-- chain with enough context to do it. The carrier loop locks to an arbitrary
-- multiple of 90 degrees; all four rotations of the sync word are compared
-- simultaneously, and whichever matches names the rotation. Every subsequent
-- symbol is derotated by its inverse. See the long note in pkg.vhd.
--
-- FALSE SYNC: a 32-bit word matched against 4 rotations gives a false-lock
-- probability of about 4 * 2**-32 = 2**-30 per symbol. At 1 Msym/s that is one
-- false frame roughly every 20 minutes of listening to noise. The CRC catches
-- it, so it costs an ERR_COUNT increment, not corrupt data. Tighten later with
-- a preamble-gated search window if that rate ever matters.
--
-- CRC-16-CCITT covers HEADER + PAYLOAD, init 0xFFFF, no final xor. The CRC
-- field itself is obviously not included in its own calculation.
--
-- Not simulated.
------------------------------------------------------------------------------
entity frame_sync is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        enable      : in  std_logic;                      -- CONTROL.RX_ENABLE

        valid_in    : in  std_logic;
        bits_in     : in  std_logic_vector(1 downto 0);   -- (b1, b0) from slicer

        -- payload, one byte at a time, in wire order
        byte_valid  : out std_logic;
        byte_data   : out std_logic_vector(7 downto 0);

        -- frame boundaries and verdict
        frame_start : out std_logic;                      -- pulse, header parsed
        frame_done  : out std_logic;                      -- pulse, CRC checked
        frame_ok    : out std_logic;                      -- valid with frame_done
        frame_len   : out unsigned(7 downto 0);           -- payload bytes
        frame_type  : out std_logic_vector(3 downto 0);
        frame_seq   : out std_logic_vector(3 downto 0);

        -- status
        in_frame    : out std_logic;                      -- high once synced
        -- Sync detections, whether or not the frame later passes CRC. This is
        -- the graded signal between "nothing works" and "a frame arrived": a
        -- sync match means 16 consecutive symbols were correct, which is real
        -- progress even when the frame body is still corrupt. Frame count alone
        -- is a cliff and gives a coefficient search no gradient to follow.
        sync_count  : out unsigned(15 downto 0)
    );
end frame_sync;

architecture rtl of frame_sync is

    type state_t is (ST_HUNT, ST_HEADER, ST_PAYLOAD, ST_CRC);
    signal state : state_t := ST_HUNT;

    -- Sync hunt shift register. Newest symbol in the low bits, so after 16
    -- symbols this holds the sync word exactly as transmitted (MSB first).
    signal sr : std_logic_vector(31 downto 0) := (others => '0');

    -- Rotation to APPLY to incoming symbols to undo the carrier ambiguity,
    -- i.e. already the inverse of the detected rotation.
    signal rot_inv : natural range 0 to 3 := 0;

    signal hdr_sr      : std_logic_vector(15 downto 0) := (others => '0');
    signal crc_reg     : std_logic_vector(15 downto 0) := (others => '1');
    signal crc_rx      : std_logic_vector(15 downto 0) := (others => '0');

    signal payload_len : unsigned(7 downto 0) := (others => '0');
    signal byte_cnt    : unsigned(7 downto 0) := (others => '0');
    signal byte_sr     : std_logic_vector(7 downto 0) := (others => '0');

    -- 4 symbols per byte, 8 symbols per 16-bit field
    signal sym_cnt : unsigned(2 downto 0) := (others => '0');

    signal syncs : unsigned(15 downto 0) := (others => '0');

begin

    in_frame   <= '0' when state = ST_HUNT else '1';
    sync_count <= syncs;

    process (clk)
        variable sr_v    : std_logic_vector(31 downto 0);
        variable drot    : std_logic_vector(1 downto 0);
        variable hdr_v   : std_logic_vector(15 downto 0);
        variable crc_v   : std_logic_vector(15 downto 0);
        variable byte_v  : std_logic_vector(7 downto 0);
        variable rxc_v   : std_logic_vector(15 downto 0);
        variable matched : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' or enable = '0' then
                state       <= ST_HUNT;
                sr          <= (others => '0');
                rot_inv     <= 0;
                crc_reg     <= (others => '1');
                byte_cnt    <= (others => '0');
                sym_cnt     <= (others => '0');
                payload_len <= (others => '0');
                byte_valid  <= '0';
                frame_start <= '0';
                frame_done  <= '0';
                frame_ok    <= '0';

                -- syncs survives rx_enable going low - otherwise disabling the
                -- receiver between captures would wipe the diagnostic that
                -- explains why the previous capture failed. Only a hard reset
                -- clears it.
                if rst = '1' then
                    syncs <= (others => '0');
                end if;
            else
                -- single-cycle outputs default low
                byte_valid  <= '0';
                frame_start <= '0';
                frame_done  <= '0';

                if valid_in = '1' then
                    case state is

                    ----------------------------------------------------------
                    when ST_HUNT =>
                        -- Compare the POST-shift value. Reading the sr signal
                        -- here would test the previous symbol's contents - the
                        -- same read-before-write trap that made ddc_fs_4 output
                        -- zero and the matched filter convolve one tap.
                        sr_v := sr(29 downto 0) & bits_in;
                        sr   <= sr_v;

                        matched := false;
                        for k in 0 to 3 loop
                            -- rotate_qpsk of a constant by a static k folds at
                            -- elaboration: four constants, four comparators.
                            if (not matched) and sr_v = rotate_qpsk(C_SYNC_WORD, k) then
                                matched := true;
                                rot_inv <= (4 - k) mod 4;
                            end if;
                        end loop;

                        if matched then
                            state   <= ST_HEADER;
                            crc_reg <= (others => '1');
                            sym_cnt <= (others => '0');
                            syncs   <= syncs + 1;
                        end if;

                    ----------------------------------------------------------
                    when ST_HEADER =>
                        drot  := rotate_qpsk(bits_in, rot_inv);
                        hdr_v := hdr_sr(13 downto 0) & drot;
                        hdr_sr <= hdr_v;

                        crc_v := crc16_step(crc_reg, drot(1));
                        crc_v := crc16_step(crc_v,  drot(0));
                        crc_reg <= crc_v;

                        if sym_cnt = 7 then      -- 8 symbols = 16 header bits
                            payload_len <= unsigned(hdr_v(C_HDR_LEN_RANGE));
                            frame_len   <= unsigned(hdr_v(C_HDR_LEN_RANGE));
                            frame_type  <= hdr_v(C_HDR_TYPE_RANGE);
                            frame_seq   <= hdr_v(C_HDR_SEQ_RANGE);
                            frame_start <= '1';

                            byte_cnt <= (others => '0');
                            sym_cnt  <= (others => '0');

                            -- A zero-length payload is legal (ACK frames), and
                            -- would otherwise underflow the byte_cnt compare
                            -- below and run for 256 bytes.
                            if unsigned(hdr_v(C_HDR_LEN_RANGE)) = 0 then
                                state <= ST_CRC;
                            else
                                state <= ST_PAYLOAD;
                            end if;
                        else
                            sym_cnt <= sym_cnt + 1;
                        end if;

                    ----------------------------------------------------------
                    when ST_PAYLOAD =>
                        drot   := rotate_qpsk(bits_in, rot_inv);
                        byte_v := byte_sr(5 downto 0) & drot;
                        byte_sr <= byte_v;

                        crc_v := crc16_step(crc_reg, drot(1));
                        crc_v := crc16_step(crc_v,  drot(0));
                        crc_reg <= crc_v;

                        if sym_cnt(1 downto 0) = "11" then   -- 4 symbols = 1 byte
                            byte_data  <= byte_v;
                            byte_valid <= '1';
                            sym_cnt    <= (others => '0');

                            if byte_cnt = payload_len - 1 then
                                state   <= ST_CRC;
                                sym_cnt <= (others => '0');
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;
                        else
                            sym_cnt <= sym_cnt + 1;
                        end if;

                    ----------------------------------------------------------
                    when ST_CRC =>
                        -- The CRC field is not fed into crc_reg - it is not
                        -- covered by its own checksum.
                        drot   := rotate_qpsk(bits_in, rot_inv);
                        rxc_v  := crc_rx(13 downto 0) & drot;
                        crc_rx <= rxc_v;

                        if sym_cnt = 7 then      -- 8 symbols = 16 CRC bits
                            frame_done <= '1';
                            if rxc_v = crc_reg then
                                frame_ok <= '1';
                            else
                                frame_ok <= '0';
                            end if;
                            state   <= ST_HUNT;
                            sr      <= (others => '0');
                            sym_cnt <= (others => '0');
                        else
                            sym_cnt <= sym_cnt + 1;
                        end if;

                    end case;
                end if;
            end if;
        end if;
    end process;

end rtl;
