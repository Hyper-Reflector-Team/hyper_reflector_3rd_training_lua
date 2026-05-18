-- @module hr_data_collector
-- Per-match stat collection for Hyper Reflector.
-- Uses direct memory reads so it operates independently of the gamestate
-- update cycle (which is not active in the hyper_reflector.lua context).
--
-- Usage:
--   local hr_data_collector = require("src/modules/hr_data_collector")
--   hr_data_collector.reset()          -- call at match start
--   hr_data_collector.update()         -- call every frame during match
--   hr_data_collector.get_stats()      -- call before writing match file

-- ── Player base addresses ──────────────────────────────────────────────────────

local P1_BASE = 0x02068C6C
local P2_BASE = 0x02069104

-- ── Absolute superfreeze addresses ────────────────────────────────────────────
-- Each player's superfreeze counter is stored in the opponent's memory region.
-- When it transitions 0→non-zero, the owning player used a super.

local P1_SUPERFREEZE_ADDR = 0x02069520  -- P1's super counter (sits in P2 memory region)
local P2_SUPERFREEZE_ADDR = 0x02069088  -- P2's super counter (sits in P1 memory region)

-- ── Memory offsets (relative to player base) ──────────────────────────────────

local OFFSET_FLYING_DOWN       = 0x8D   -- 1 while in hard knockdown flight; 1→0 signals landing
local OFFSET_STANDING_STATE    = 0x297  -- 0 during knockdown/wakeup, non-0 when standing/crouching
local OFFSET_MOVEMENT_TYPE     = 0x0AD  -- 2 = Hugo grab, 5 = Ryu reversal DP (knockdown exclusions)
local OFFSET_MOVEMENT_TYPE2    = 0x0AF  -- upper nibble == 9 means player is executing a throw
local OFFSET_POSTURE           = 0x20E  -- 0x26 = wakeup posture; transition away clears wakeup state
local OFFSET_FAST_WU_FLAG      = 0x403  -- 1→0 when fast wakeup input is executed
local OFFSET_CONNECTION_MARKER = 0x32E  -- word; 0→0xFFF1 = successful parry by this player
local OFFSET_IS_BEING_THROWN   = 0x3CF  -- non-zero while this player is being thrown (victim)
local OFFSET_ACTION            = 0xAC   -- dword; 43 = defender throw tech, 44 = attacker throw was teched
local OFFSET_THROW_COUNTDOWN   = 0x434  -- non-zero while a connected throw is in progress

-- ── Internal state ─────────────────────────────────────────────────────────────

local stats = {}
local prev  = {}

local function make_player_prev()
    return {
        flying_down          = 0,
        fast_wu_flag         = 0,
        posture              = 0,
        is_waking_up         = false,
        is_throwing          = false,
        throw_countdown      = 0,
        throw_pending        = false,  -- true from throw start until resolved (connect/tech/whiff)
        throw_pending_frames = 0,      -- frames elapsed since is_throwing ended
        connection_marker    = 0,
        action               = 0,
    }
end

local function reset()
    stats = {
        p1 = { knockdowns = 0, fast_wakeups = 0, parries = 0, throws = 0, throw_whiffs = 0, supers_used = 0, throw_techs = 0 },
        p2 = { knockdowns = 0, fast_wakeups = 0, parries = 0, throws = 0, throw_whiffs = 0, supers_used = 0, throw_techs = 0 },
    }
    prev = {
        p1             = make_player_prev(),
        p2             = make_player_prev(),
        p1_superfreeze = 0,
        p2_superfreeze = 0,
    }
end

-- Initialise on load so the table is always valid before the first reset() call.
reset()

-- ── Per-player per-frame update ────────────────────────────────────────────────

local function update_player(base, s, p)
    local flying_down       = memory.readbyte(base + OFFSET_FLYING_DOWN)
    local standing_state    = memory.readbyte(base + OFFSET_STANDING_STATE)
    local movement_type     = memory.readbyte(base + OFFSET_MOVEMENT_TYPE)
    local movement_type2    = memory.readbyte(base + OFFSET_MOVEMENT_TYPE2)
    local posture           = memory.readbyte(base + OFFSET_POSTURE)
    local fast_wu_flag      = memory.readbyte(base + OFFSET_FAST_WU_FLAG)
    local connection_marker = memory.readword(base + OFFSET_CONNECTION_MARKER)
    local is_being_thrown   = memory.readbyte(base + OFFSET_IS_BEING_THROWN)
    local action            = memory.readdword(base + OFFSET_ACTION)
    local throw_countdown   = memory.readbyte(base + OFFSET_THROW_COUNTDOWN)

    -- Knockdown: flying_down 1→0 while grounded, excluding Hugo grab and Ryu reversal DP.
    if p.flying_down == 1 and flying_down == 0 and standing_state == 0
        and movement_type ~= 2 and movement_type ~= 5 then
        s.knockdowns   = s.knockdowns + 1
        p.is_waking_up = true
    end

    if p.is_waking_up then
        if p.fast_wu_flag == 1 and fast_wu_flag == 0 then
            s.fast_wakeups = s.fast_wakeups + 1
        end
        if p.posture == 0x26 and posture ~= 0x26 then
            p.is_waking_up = false
        end
    end

    -- Parry: connection_marker transitions 0→0xFFF1.
    if p.connection_marker == 0 and connection_marker == 0xFFF1 then
        s.parries = s.parries + 1
    end

    local is_throwing = bit.rshift(movement_type2, 4) == 9 and is_being_thrown == 0

    -- Successful throw: throw_countdown increases (new grab landed), attacker only.
    -- Tracked independently of is_throwing because the countdown often rises after
    -- the movement_type2 startup window has already closed.
    if throw_countdown > p.throw_countdown and is_being_thrown == 0 then
        s.throws = s.throws + 1
        p.throw_pending = false
    end

    -- Whiff detection: open a pending window when a throw attempt starts.
    if is_throwing and not p.is_throwing then
        p.throw_pending        = true
        p.throw_pending_frames = 0
    end

    if p.throw_pending then
        if not is_throwing then
            p.throw_pending_frames = p.throw_pending_frames + 1
        end
        if action == 44 then
            -- Throw was teched by opponent — not a whiff.
            p.throw_pending = false
        elseif p.throw_pending_frames > 8 then
            -- Enough frames have passed with no connection and no tech → whiff.
            s.throw_whiffs = s.throw_whiffs + 1
            p.throw_pending = false
        end
    end

    -- Throw tech: action transitions into 43 (this player escaped a throw attempt).
    if p.action ~= 43 and action == 43 then
        s.throw_techs = s.throw_techs + 1
    end

    p.flying_down       = flying_down
    p.fast_wu_flag      = fast_wu_flag
    p.posture           = posture
    p.is_throwing       = is_throwing
    p.throw_countdown   = throw_countdown
    p.connection_marker = connection_marker
    p.action            = action
end

-- ── Public API ─────────────────────────────────────────────────────────────────

local function update()
    update_player(P1_BASE, stats.p1, prev.p1)
    update_player(P2_BASE, stats.p2, prev.p2)

    -- Super: each player's superfreeze counter is at an absolute address.
    -- 0→non-zero transition means that player activated a super.
    local p1_sf = memory.readbyte(P1_SUPERFREEZE_ADDR)
    local p2_sf = memory.readbyte(P2_SUPERFREEZE_ADDR)
    if p1_sf > 0 and prev.p1_superfreeze == 0 then
        stats.p1.supers_used = stats.p1.supers_used + 1
    end
    if p2_sf > 0 and prev.p2_superfreeze == 0 then
        stats.p2.supers_used = stats.p2.supers_used + 1
    end
    prev.p1_superfreeze = p1_sf
    prev.p2_superfreeze = p2_sf
end

local function get_stats()
    return {
        p1 = {
            knockdowns   = stats.p1.knockdowns,
            fast_wakeups = stats.p1.fast_wakeups,
            parries      = stats.p1.parries,
            throws       = stats.p1.throws,
            throw_whiffs = stats.p1.throw_whiffs,
            supers_used  = stats.p1.supers_used,
            throw_techs  = stats.p1.throw_techs,
        },
        p2 = {
            knockdowns   = stats.p2.knockdowns,
            fast_wakeups = stats.p2.fast_wakeups,
            parries      = stats.p2.parries,
            throws       = stats.p2.throws,
            throw_whiffs = stats.p2.throw_whiffs,
            supers_used  = stats.p2.supers_used,
            throw_techs  = stats.p2.throw_techs,
        },
    }
end

return {
    reset     = reset,
    update    = update,
    get_stats = get_stats,
}
