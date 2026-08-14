library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.all;

package pkg is

constant C_ADDR_WIDTH : natural := 32;
constant C_DATA_WIDTH : natural := 32;

------------------------------------------------------------------------------
-- Register map, as seen by the PS through the AXI4-Lite window at 0x43C0_0000
-- (word offsets: reg N sits at byte offset N*4).
--
--   0x00  ID_VERSION   RO
--   0x04  CONTROL      RW
--   0x08  MODE         RW
--   0x0C  STATUS       RO
--   0x10  TX_LEN       RW
--   0x14  RX_LEN       RO
--   0x18  FRAME_COUNT  RO
--   0x1C  ERR_COUNT    RO
--   0x20  SYNC_COUNT   RO
--   0x24  QUAL_MIN     RO
--   0x28  QUAL_MAX     RO
--   0x2C  QUAL_SYMS    RO
--   0x30  BUILD_ID     RO
------------------------------------------------------------------------------
constant C_REG_ID          : natural := 0;
constant C_REG_CONTROL     : natural := 1;
constant C_REG_MODE        : natural := 2;
constant C_REG_STATUS      : natural := 3;
constant C_REG_TX_LEN      : natural := 4;
constant C_REG_RX_LEN      : natural := 5;
constant C_REG_FRAME_COUNT : natural := 6;
constant C_REG_ERR_COUNT   : natural := 7;

-- Lock quality. SYNC_COUNT is the graded step between "nothing works" and "a
-- frame arrived" - each sync means 16 consecutive symbols were right, which is
-- real progress even while the frame body still fails CRC.
--
-- QUAL_MIN/QUAL_MAX are accumulators; the PS forms the ratio
-- QUAL_MIN/QUAL_MAX, which approaches 1.0 for a clean QPSK constellation on
-- the diagonal and degrades smoothly with phase error, ISI and noise. The
-- ratio is deliberately scale-free - there is no AGC, so an absolute error
-- measure would track signal level rather than lock quality. QUAL_SYMS is the
-- number of symbols the accumulators cover.
constant C_REG_SYNC_COUNT  : natural := 8;
constant C_REG_QUAL_MIN    : natural := 9;
constant C_REG_QUAL_MAX    : natural := 10;
constant C_REG_QUAL_SYMS   : natural := 11;

-- 0x30 BUILD_ID: first 32 bits of the git commit the bitstream was built from,
-- injected at project-creation time by create_project.tcl.
--
-- Answers "is the PL actually the design I think it is?", which is otherwise
-- unanswerable from a running system - and has been the wrong assumption more
-- than once here.
--
-- ALWAYS read it together with STATUS.BUILD_DIRTY. A commit hash on its own is
-- misleading during development, because the normal working state is a tree
-- with uncommitted changes: the hash names the last commit while the bitstream
-- contains something else. Dirty means "this hash is a lower bound on what is
-- in here, not an identification".
constant C_REG_BUILD_ID    : natural := 12;

constant C_REG_COUNT : natural := 13;  -- number of addressable words

-- Read back at ID_VERSION to confirm which bitstream is loaded.
-- "Zy" + version; bump the low half on register map changes.
constant C_ID_MAGIC : std_logic_vector(31 downto 0) := x"5A790001";

-- CONTROL bit positions
constant C_CTRL_ENABLE    : natural := 0;
constant C_CTRL_TX_START  : natural := 1;   -- write-one pulse, self-clearing
constant C_CTRL_RX_ENABLE : natural := 2;
constant C_CTRL_CLR_STATS : natural := 3;   -- write-one pulse, self-clearing

-- MODE bit positions
constant C_MODE_ROLE      : natural := 0;   -- '0' = RX, '1' = TX
subtype  C_MODE_MOD_RANGE   is natural range 3 downto 1;
subtype  C_MODE_SPREAD_RANGE is natural range 7 downto 4;

-- STATUS bit positions (driven from PL)
constant C_STAT_TX_BUSY     : natural := 0;
constant C_STAT_PLL_LOCKED  : natural := 1;
constant C_STAT_FRAME_VALID : natural := 2;
constant C_STAT_OVERFLOW    : natural := 3;
-- Set when the bitstream was built from a tree with uncommitted changes, i.e.
-- BUILD_ID does not fully identify what is in the PL.
constant C_STAT_BUILD_DIRTY : natural := 4;

-- PS -> PL: the writable registers, one entry per word offset. Read-only
-- offsets are present but unused in this array.
type fpgaReg32 is array (0 to C_REG_COUNT-1) of std_logic_vector(C_DATA_WIDTH-1 downto 0);

-- PL -> PS: values the PL drives back for the read-only offsets.
type fpgaStatus32 is array (0 to C_REG_COUNT-1) of std_logic_vector(C_DATA_WIDTH-1 downto 0);

------------------------------------------------------------------------------
-- Frame format v1
--   | PREAMBLE 32 | SYNC 32 | HEADER 16 | PAYLOAD 0-255B | CRC16 |
------------------------------------------------------------------------------
-- PREAMBLE is 0xCCCC..., NOT the 0xAAAA... an alternating bit pattern would
-- suggest. The preamble's only job is to drive the acquisition loops, and under
-- this QPSK mapping those two patterns behave completely differently:
--
--   0xAAAA... = 10 10 10 ...  every symbol pair is (b1,b0) = (1,0)
--                             -> the SAME constellation point every time
--   0xCCCC... = 11 00 11 ...  pairs alternate (1,1), (0,0)
--                             -> two antipodal points, a transition every symbol
--
-- A constant symbol is the worst possible preamble here. Gardner's error term
-- is (I[k] - I[k-1]) * I[k-1/2]; with no symbol transitions that difference is
-- zero and the timing loop gets NO error signal at all - it cannot acquire,
-- and would sit at whatever phase it powered up in until real data arrived.
--
-- 0xCCCC... gives a transition on every symbol, which is the maximum-density
-- timing information the detector can be given, and reduces to BPSK for the
-- carrier loop. Alternating bits are the right instinct at the BIT level; this
-- constellation cares about the SYMBOL level.
--
-- The RX does not search for the preamble (frame_sync hunts the sync word), so
-- this is a transmit-side constant only - changing it costs nothing in the
-- receiver.
constant C_PREAMBLE  : std_logic_vector(31 downto 0) := x"CCCCCCCC";
constant C_SYNC_WORD : std_logic_vector(31 downto 0) := x"1ACFFC1D";  -- CCSDS ASM
constant C_CRC_POLY  : std_logic_vector(15 downto 0) := x"1021";      -- CRC-16-CCITT

constant C_FRAME_TYPE_CMD  : std_logic_vector(3 downto 0) := x"0";
constant C_FRAME_TYPE_DATA : std_logic_vector(3 downto 0) := x"1";
constant C_FRAME_TYPE_ACK  : std_logic_vector(3 downto 0) := x"2";

constant C_MAX_PAYLOAD_BYTES : natural := 255;

-- HEADER 16 bits, MSB first on the wire: | TYPE 4 | LEN 8 | SEQ 4 |
-- LEN is payload bytes, so 255 max, which is what C_MAX_PAYLOAD_BYTES says.
subtype C_HDR_TYPE_RANGE is natural range 15 downto 12;
subtype C_HDR_LEN_RANGE  is natural range 11 downto  4;
subtype C_HDR_SEQ_RANGE  is natural range  3 downto  0;

-- Payload rounded up to whole 32-bit words, for the RX frame buffer.
constant C_MAX_PAYLOAD_WORDS : natural := (C_MAX_PAYLOAD_BYTES + 3) / 4;

------------------------------------------------------------------------------
-- QPSK bit mapping and the 90-degree phase ambiguity
--
-- Gray-mapped QPSK, hard decision = the two sign bits:
--   b1 = 1 when I < 0,  b0 = 1 when Q < 0
--
-- A Costas/2nd-order carrier loop locks to any of four phases - it has no way
-- to tell which quadrant is "up", because a QPSK constellation is symmetric
-- under 90-degree rotation. So the recovered bit pairs may be rotated by
-- k*90 degrees relative to what was transmitted, and k is unknowable from the
-- constellation alone.
--
-- Resolution used here: the sync word breaks the symmetry. rotate_qpsk() below
-- pre-rotates the sync word by all four k at elaboration time; the frame
-- detector compares against all four at once, and whichever matches tells us k.
-- Every subsequent symbol is then derotated by (4-k) mod 4.
--
-- The alternative is differential encoding (DQPSK), which resolves the
-- ambiguity without a sync word but roughly doubles the bit error rate,
-- because an error in one symbol corrupts its neighbour too. Not worth it when
-- a sync word is already in the frame for other reasons.
--
-- Rotating (I,Q) by +90 gives (-Q, I), which in bits is:
--   k=0: (b1, b0)          k=1: (not b0, b1)
--   k=2: (not b1, not b0)  k=3: (b0, not b1)
------------------------------------------------------------------------------
function rotate_qpsk (v : std_logic_vector; k : natural) return std_logic_vector;

-- CRC-16-CCITT, one bit at a time, MSB-first. Init 0xFFFF, no final xor.
function crc16_step (crc : std_logic_vector(15 downto 0);
                     b   : std_logic) return std_logic_vector;

------------------------------------------------------------------------------
-- Sample-rate source for the DSP chain.
--
-- The chain is sample-rate agnostic - it advances one sample per data_valid,
-- regardless of the 100 MHz system clock - so no clock conversion is needed,
-- only the right strobe. This generic picks where that strobe comes from:
--
--   VALID_ALWAYS - tied high; effective rate = system clock. Simulation only.
--   VALID_DMA    - AXI-Stream tvalid from the MM2S channel. Normal build.
--   VALID_ADC    - external ADC sample strobe. Not wired yet; add the port
--                  to system_top when the ADC path exists.
--
-- An enum rather than a string so a typo is an elaboration error instead of
-- silently selecting the fallback branch.
------------------------------------------------------------------------------
type valid_src_t is (VALID_ALWAYS, VALID_DMA, VALID_ADC);

constant C_UART_BASE_ADDR    : unsigned(31 downto 0) := x"40600000";
constant C_AXI_BASE_ADDR     : unsigned(31 downto 0) := x"43C00000";
constant C_LED_CONTROL_ADDR  : unsigned(31 downto 0) := x"40600004";
constant C_LED_CONTROL_ADDR_IND : natural := 1;

function or_reduct(vec : std_logic_vector) return std_logic;
end pkg;

--define any functions prototyped in package
package body pkg is

function or_reduct(vec : std_logic_vector) return std_logic is
    variable result : std_logic := '0';
begin
    for i in vec'range loop
        result := result or vec(i);
    end loop;
    return result;
end function;

-- Applies the rotation to every 2-bit symbol in the vector. Length must be
-- even; symbol s occupies bits (2s+1, 2s) with 2s+1 as b1.
function rotate_qpsk (v : std_logic_vector; k : natural) return std_logic_vector is
    variable src : std_logic_vector(v'length-1 downto 0) := v;
    variable r   : std_logic_vector(v'length-1 downto 0) := (others => '0');
    variable b1  : std_logic;
    variable b0  : std_logic;
begin
    assert (v'length mod 2) = 0
        report "rotate_qpsk: vector length must be even (2 bits per symbol)"
        severity failure;

    for s in 0 to v'length/2 - 1 loop
        b1 := src(2*s + 1);
        b0 := src(2*s);
        case k mod 4 is
            when 0 =>
                r(2*s + 1) := b1;      r(2*s) := b0;
            when 1 =>
                r(2*s + 1) := not b0;  r(2*s) := b1;
            when 2 =>
                r(2*s + 1) := not b1;  r(2*s) := not b0;
            when others =>
                r(2*s + 1) := b0;      r(2*s) := not b1;
        end case;
    end loop;
    return r;
end function;

function crc16_step (crc : std_logic_vector(15 downto 0);
                     b   : std_logic) return std_logic_vector is
    variable fb : std_logic;
    variable r  : std_logic_vector(15 downto 0);
begin
    fb := crc(15) xor b;
    r  := crc(14 downto 0) & '0';
    if fb = '1' then
        r := r xor C_CRC_POLY;
    end if;
    return r;
end function;

end pkg;
