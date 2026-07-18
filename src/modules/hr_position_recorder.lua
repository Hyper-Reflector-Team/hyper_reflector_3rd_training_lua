-- @module hr_position_recorder
-- Records per-frame state for local replay playback.
-- Frame: { p1x, p1y, p2x, p2y, p1hp, p2hp, p1sa, p2sa, {{px,py},...},
--          p1stun, p2stun, p1stun_max, p2stun_max,
--          p1stun_timer, p2stun_timer, p1stun_activate, p2stun_activate,
--          p1posture, p2posture }
-- Written to disk once at match end.

local P1_BASE = 0x02068C6C
local P2_BASE = 0x02069104

local OFFSET_POS_X   = 0x64
local OFFSET_POS_Y   = 0x68
local OFFSET_LIFE    = 0x9F
local OFFSET_POSTURE = 0x20E

local P1_GAUGE      = 0x020695B5
local P2_GAUGE      = 0x020695E1

local P1_STUN          = 0x020695FD  -- stun_bar_char: P1_stun_bar_max + 0x6
local P2_STUN          = 0x02069611  -- stun_bar_char: P2_stun_bar_max + 0x6
local P1_STUN_MAX      = 0x020695F7  -- stun_bar_max for P1
local P2_STUN_MAX      = 0x0206960B  -- stun_bar_max for P2
local P1_STUN_TIMER    = 0x020695F9  -- stun_timer: P1_stun_bar_max + 0x2 (counts down during dizzy)
local P2_STUN_TIMER    = 0x0206960D  -- stun_timer: P2_stun_bar_max + 0x2
local P1_STUN_ACTIVATE = 0x020695F4  -- stun_activate: P1_stun_bar_max - 0x3 (1 on dizzy start)
local P2_STUN_ACTIVATE = 0x02069608  -- stun_activate: P2_stun_bar_max - 0x3

local PROJ_INDEX     = 0x02068A96
local PROJ_INITIAL   = 0x02028990
local PROJ_LIST      = 3
local OFFSET_OBJ_NEXT  = 0x1C
local OFFSET_OBJ_VALID = 0x2A0

local frames = {}

local function reset()
    frames = {}
end

reset()

local function collect_projectiles()
    local obj_index = memory.readwordsigned(PROJ_INDEX + PROJ_LIST * 2)
    local projs = {}
    local slot = 1
    while slot <= 30 and obj_index ~= -1 do
        local base = PROJ_INITIAL + bit.lshift(obj_index, 11)
        if memory.readdword(base + OFFSET_OBJ_VALID) ~= 0 then
            local px = memory.readwordsigned(base + OFFSET_POS_X)
            local py = memory.readwordsigned(base + OFFSET_POS_Y)
            projs[#projs + 1] = { px, py }
        end
        obj_index = memory.readwordsigned(base + OFFSET_OBJ_NEXT)
        slot = slot + 1
    end
    return projs
end

local function update()
    local p1x             = memory.readwordsigned(P1_BASE + OFFSET_POS_X)
    local p1y             = memory.readwordsigned(P1_BASE + OFFSET_POS_Y)
    local p2x             = memory.readwordsigned(P2_BASE + OFFSET_POS_X)
    local p2y             = memory.readwordsigned(P2_BASE + OFFSET_POS_Y)
    local p1hp            = memory.readbyte(P1_BASE + OFFSET_LIFE)
    local p2hp            = memory.readbyte(P2_BASE + OFFSET_LIFE)
    local p1sa            = memory.readbyte(P1_GAUGE)
    local p2sa            = memory.readbyte(P2_GAUGE)
    local p1stun          = memory.readbyte(P1_STUN)
    local p2stun          = memory.readbyte(P2_STUN)
    local p1stun_max      = memory.readbyte(P1_STUN_MAX)
    local p2stun_max      = memory.readbyte(P2_STUN_MAX)
    local p1stun_timer    = memory.readbyte(P1_STUN_TIMER)
    local p2stun_timer    = memory.readbyte(P2_STUN_TIMER)
    local p1stun_activate = memory.readbyte(P1_STUN_ACTIVATE)
    local p2stun_activate = memory.readbyte(P2_STUN_ACTIVATE)
    local p1posture       = memory.readbyte(P1_BASE + OFFSET_POSTURE)
    local p2posture       = memory.readbyte(P2_BASE + OFFSET_POSTURE)
    frames[#frames + 1] = {
        p1x, p1y, p2x, p2y, p1hp, p2hp, p1sa, p2sa,
        collect_projectiles(),
        p1stun, p2stun, p1stun_max, p2stun_max,
        p1stun_timer, p2stun_timer, p1stun_activate, p2stun_activate,
        p1posture, p2posture
    }
end

local function write(path)
    local f = io.open(path, "w")
    if not f then return end
    f:write('{"frames":[')
    for i, fr in ipairs(frames) do
        if i > 1 then f:write(',') end
        f:write('[')
        f:write(fr[1])  f:write(',')   -- p1x
        f:write(fr[2])  f:write(',')   -- p1y
        f:write(fr[3])  f:write(',')   -- p2x
        f:write(fr[4])  f:write(',')   -- p2y
        f:write(fr[5])  f:write(',')   -- p1hp
        f:write(fr[6])  f:write(',')   -- p2hp
        f:write(fr[7])  f:write(',')   -- p1sa
        f:write(fr[8])  f:write(',')   -- p2sa
        f:write('[')                    -- projs
        for j, p in ipairs(fr[9]) do
            if j > 1 then f:write(',') end
            f:write('[') f:write(p[1]) f:write(',') f:write(p[2]) f:write(']')
        end
        f:write(']')    f:write(',')
        f:write(fr[10]) f:write(',')   -- p1stun
        f:write(fr[11]) f:write(',')   -- p2stun
        f:write(fr[12]) f:write(',')   -- p1stun_max
        f:write(fr[13]) f:write(',')   -- p2stun_max
        f:write(fr[14]) f:write(',')   -- p1stun_timer
        f:write(fr[15]) f:write(',')   -- p2stun_timer
        f:write(fr[16]) f:write(',')   -- p1stun_activate
        f:write(fr[17]) f:write(',')   -- p2stun_activate
        f:write(fr[18]) f:write(',')   -- p1posture
        f:write(fr[19])                -- p2posture
        f:write(']')
    end
    f:write(']}')
    f:close()
end

return {
    reset  = reset,
    update = update,
    write  = write,
}
