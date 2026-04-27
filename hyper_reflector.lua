GLOBAL_isHyperReflectorOnline = true
-- BEFORE BUILDING COPY THIS FILE TO lua/3rd_training_lua/ in order for the scripts to use the same root directories.
local third_training = require("3rd_training")
local util_draw = require("src/utils/draw");
local util_colors = require("src/utils/colors")
require("src/tools")

local function resolve_files_base()
    local source = debug.getinfo(1, "S").source or ''
    if source:sub(1, 1) == '@' then source = source:sub(2) end
    source = source:gsub('\\', '/')
    local dir = source:match("^(.*)/[^/]+$") or '.'
    local files_dir = dir:gsub('/lua/3rd_training_lua$', '')
    return files_dir
end

local FILES_BASE = resolve_files_base()
local function join_files_path(relative) return FILES_BASE .. '/' .. relative end

local ext_command_file = join_files_path("hyper_read_commands.txt")
local match_track_file = join_files_path("hyper_track_match.txt")
local module_character_select = require("src/modules/character_select")

-- game state
require("src/gamestate")

math.randomseed(os.time())

local function unique_id()
    return tostring(os.time()) .. tostring(math.random(100000, 999999))
end

local function escape_json_string(str)
    if not str then return '' end
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    str = str:gsub('\b', '\\b')
    str = str:gsub('\f', '\\f')
    str = str:gsub('\n', '\\n')
    str = str:gsub('\r', '\\r')
    str = str:gsub('\t', '\\t')
    return str
end

local function is_array(tbl)
    if type(tbl) ~= 'table' then return false end
    local count = 0
    for key, _ in pairs(tbl) do
        if type(key) ~= 'number' then return false end
        count = count + 1
    end
    return count == #tbl
end

local function encode_json(value)
    local t = type(value)
    if t == 'nil' then return 'null' end
    if t == 'number' then return tostring(value) end
    if t == 'boolean' then return value and 'true' or 'false' end
    if t == 'string' then return '"' .. escape_json_string(value) .. '"' end
    if t == 'table' then
        local buffer = {}
        if is_array(value) then
            for i = 1, #value do
                buffer[#buffer + 1] = encode_json(value[i])
            end
            return '[' .. table.concat(buffer, ',') .. ']'
        else
            local keys = {}
            for key, _ in pairs(value) do keys[#keys + 1] = key end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, key in ipairs(keys) do
                buffer[#buffer + 1] =
                    '"' .. escape_json_string(tostring(key)) .. '":' ..
                        encode_json(value[key])
            end
            return '{' .. table.concat(buffer, ',') .. '}'
        end
    end
    return 'null'
end

local function parse_match_text(raw)
    if not raw or raw == '' then return nil end

    local result = {}

    for line in raw:gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", "")
        trimmed = trimmed:gsub("%s+$", "")
        if trimmed ~= '' then
            local key, value = trimmed:match("^([^:]+):?(.*)$")
            if key then
                key = key:gsub("%s+$", "")
                value = value or ''
                value = value:gsub("^%s+", "")
                local parsed_value = nil
                if value ~= '' then
                    local lower = value:lower()
                    if lower == 'true' then
                        parsed_value = true
                    elseif lower == 'false' then
                        parsed_value = false
                    else
                        parsed_value = tonumber(value) or value
                    end
                end

                if parsed_value ~= nil then
                    if result[key] ~= nil then
                        if type(result[key]) ~= 'table' or
                            not is_array(result[key]) then
                            result[key] = {result[key]}
                        end
                        table.insert(result[key], parsed_value)
                    else
                        result[key] = parsed_value
                    end
                end
            end
        end
    end

    if result["match-uuid"] == nil then result["match-uuid"] = match_uuid end

    return result
end

local function convert_match_file_to_json()
    local source = io.open(match_track_file, "r")
    if not source then return false end
    local raw = source:read("*a")
    source:close()
    local payload = parse_match_text(raw)
    if not payload then return false end
    payload["created-at"] = payload["created-at"] or os.time()
    payload["converted-at"] = os.time()
    local encoded = encode_json(payload)
    local writer = io.open(match_track_file, "w")
    if not writer then return false end
    writer:write(encoded)
    writer:close()
    return true
end

-- state
local game_name = ""
local match_uuid = ''
local match_count = 0
local total_match_count = 0
local stat_file
-- match related
local match_just_ended = false
local has_match_transitioned = false
local p1_char
local p2_char
local p1_super
local p2_super
local wins_checked = false
local close_frame_delay = 0
-- baseline win counts captured at character select (for change detection)
local last_win_count_p1 = 0
local last_win_count_p2 = 0

-- match state
local match_initialized = false
---- meter
local p1_previous_meter = 0
local p1_match_total_meter_gained = 0
local p2_previous_meter = 0
local p2_match_total_meter_gained = 0
----
---- hits
local p2_hits_landed_normals = 0
local p2_hits_landed_specials = 0
local p2_hits_landed_supers = 0
local p2_hits_landed_supers_ext = 0
local p1_hits_landed_normals = 0
local p1_hits_landed_specials = 0
local p1_hits_landed_supers = 0
local p1_hits_landed_supers_ext = 0
----
-- player_1_win_count / player_2_win_count track the real memory values after each detected win
local player_1_win_count = 0
local player_2_win_count = 0
local player_1_total_wins = 0
local player_2_total_wins = 0

local function hyper_reflector_rendering()
    if GLOBAL_isHyperReflectorOnline then
        gui.text(160, 8, player_1_total_wins, util_colors.input_history.unknown1)
        gui.text(221, 8, player_2_total_wins, util_colors.input_history.unknown1)
    end
end

local function check_in_match()
    local character_select_state = memory.readbyte(0x02015545)
    local match_state = memory.readbyte(0x020154A7)

    if character_select_state == 4 and not match_initialized and stat_file == nil then
        has_match_transitioned = false
        match_just_ended = false
        io.open(match_track_file, "w"):close()
        stat_file = io.open(match_track_file, "a")
        if stat_file then
            match_uuid = unique_id()
            stat_file:write('\n -i-game-match', match_count)
            stat_file:write('\n match-uuid:')
            stat_file:write(match_uuid)
        end
        print('resetting data')

        local current_win_count_p1 = memory.readbyte(0x02016cd5)
        local current_win_count_p2 = memory.readbyte(0x02016cd7)

        print('p1', current_win_count_p1, last_win_count_p1)
        print('p2', current_win_count_p2, last_win_count_p2)

        if current_win_count_p1 >= 100 then
            print('Ignoring overflow in p1 win count:', current_win_count_p1)
            current_win_count_p1 = 0
        end
        if current_win_count_p2 >= 100 then
            print('Ignoring overflow in p2 win count:', current_win_count_p2)
            current_win_count_p2 = 0
        end

        player_1_win_count = current_win_count_p1
        player_2_win_count = current_win_count_p2
        last_win_count_p1 = current_win_count_p1
        last_win_count_p2 = current_win_count_p2

        p1_previous_meter = 0
        p2_previous_meter = 0
        match_initialized = true
        wins_checked = false
        close_frame_delay = 0
        return
    end

    if match_state == 2 then
        p1_char = memory.readbyte(0x02011387)
        p2_char = memory.readbyte(0x02011388)
        p1_super = memory.readbyte(0x020154D3)
        p2_super = memory.readbyte(0x020154D5)
    end

    if has_match_transitioned and character_select_state == 5 and match_state == 7 then return 7 end
    if character_select_state == 5 and match_state == 2 then
        has_match_transitioned = true
        return 2
    end
end

local function detect_win()
    if wins_checked then return end
    local real_p1_win_count = memory.readbyte(0x02016cd5)
    local real_p2_win_count = memory.readbyte(0x02016cd7)

    if real_p1_win_count < player_1_win_count then player_1_win_count = real_p1_win_count end
    if real_p2_win_count < player_2_win_count then player_2_win_count = real_p2_win_count end

    if real_p1_win_count > player_1_win_count and real_p1_win_count < 100 then
        player_1_total_wins = player_1_total_wins + 1
        player_1_win_count = real_p1_win_count
        print('player 1 win detected via address change')
        if stat_file then
            stat_file:write('\n player1:')
            stat_file:write('\n player1-char:')
            stat_file:write(p1_char)
            stat_file:write('\n player1-super:')
            stat_file:write(p1_super)
            stat_file:write('\n player2-char:')
            stat_file:write(p2_char)
            stat_file:write('\n player2-super:')
            stat_file:write(p2_super)
            stat_file:write('\n p1-win:true')
            stat_file:write('\n p1-match-wins:')
            stat_file:write(player_1_total_wins)
            stat_file:write('\n p2-match-wins:')
            stat_file:write(player_2_total_wins)
        end
        match_just_ended = true
        wins_checked = true
        close_frame_delay = 2
    elseif real_p2_win_count > player_2_win_count and real_p2_win_count < 100 then
        player_2_total_wins = player_2_total_wins + 1
        player_2_win_count = real_p2_win_count
        print('player 2 win detected via address change')
        if stat_file then
            stat_file:write('\n player1-char:')
            stat_file:write(p1_char)
            stat_file:write('\n player1-super:')
            stat_file:write(p1_super)
            stat_file:write('\n player2-char:')
            stat_file:write(p2_char)
            stat_file:write('\n player2-super:')
            stat_file:write(p2_super)
            stat_file:write('\n p2-win:true')
            stat_file:write('\n p1-match-wins:')
            stat_file:write(player_1_total_wins)
            stat_file:write('\n p2-match-wins:')
            stat_file:write(player_2_total_wins)
        end
        match_just_ended = true
        wins_checked = true
        close_frame_delay = 2
    end
end

local function check_getting_hit()
    local p2_hit_by_normal = memory.readbyte(0x02028861)
    local p2_hit_by_special = memory.readbyte(0x02028863)
    -- print('p2 hit n', p2_hit_by_normal)
    -- print('p2 hit s', p2_hit_by_special)
end

-- Lua writes current stat tracking to a text file here
function GLOBAL_read_stat_memory()
    local match_state_key = check_in_match()
    if stat_file then
        if match_state_key == 2 then
            local p1_current_meter = memory.readbyte(0x020695B5)
            local p2_current_meter = memory.readbyte(0x020695E1)

            if p1_current_meter <= p1_previous_meter then
                p1_previous_meter = p1_current_meter
            end
            if p2_current_meter <= p2_previous_meter then
                p2_previous_meter = p2_current_meter
            end

            local p1_meter_gained = p1_current_meter - p1_previous_meter
            local p2_meter_gained = p2_current_meter - p2_previous_meter
            if p1_meter_gained > 0 then
                p1_match_total_meter_gained =
                    p1_match_total_meter_gained + p1_meter_gained
                p1_previous_meter = p1_current_meter
                stat_file:write('\n p1-meter-gained:')
                stat_file:write(p1_meter_gained)
                stat_file:write('\n p1-total-meter-gained:')
                stat_file:write(p1_match_total_meter_gained)
            end
            if p2_meter_gained > 0 then
                p2_match_total_meter_gained =
                    p2_match_total_meter_gained + p2_meter_gained
                p2_previous_meter = p2_current_meter
                stat_file:write('\n p2-meter-gained:')
                stat_file:write(p2_meter_gained)
                stat_file:write('\n p2-total-meter-gained:')
                stat_file:write(p2_match_total_meter_gained)
            end
        end

        -- Check win addresses every frame — write immediately on change
        detect_win()

        -- After win detected, wait a couple frames then close and signal
        if match_just_ended then
            if close_frame_delay > 0 then
                close_frame_delay = close_frame_delay - 1
            else
                p1_match_total_meter_gained = 0
                p1_previous_meter = 0
                p2_match_total_meter_gained = 0
                p2_previous_meter = 0
                match_count = match_count + 1
                total_match_count = total_match_count + 1
                match_initialized = false
                match_just_ended = false
                print('Closing stat file and signalling frontend.')
                stat_file:close()
                convert_match_file_to_json()
                stat_file = nil
                local front_end_reader = io.open(ext_command_file, "w")
                if front_end_reader then
                    front_end_reader:write('read-tracking-file')
                    front_end_reader:close()
                end
            end
        end
    end
end

local function write_simple_event(name)
    local file = io.open(match_track_file, "w")
    if file then
        file:write('{"event":"' .. name .. '"}')
        file:close()
    end
end

local function game_closing() write_simple_event('game-ended') end

local function game_starting()
    write_simple_event('game-started')
    module_character_select.start_character_select_sequence()
end

emu.registerstart(game_starting)
emu.registerexit(game_closing)
emu.registerbefore(GLOBAL_read_stat_memory)
gui.register(hyper_reflector_rendering)

-- UNCOMMENT below lines for training mode online
-- emu.registerbefore(third_training.before_frame)
-- gui.register(third_training.on_gui)
