GLOBAL_isHyperReflectorOnline = true
-- BEFORE BUILDING COPY THIS FILE TO lua/3rd_training_lua/ in order for the scripts to use the same root directories.
local third_training = require("3rd_training")
local util_draw = require("src/utils/draw");
local util_colors = require("src/utils/colors")
require("src/tools") -- TODO: refactor tools to export;
-- local command_file = "../../hyper_write_commands.txt"
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

local ext_command_file = join_files_path("hyper_read_commands.txt") -- this is for sending back commands to electron.
local match_track_file = join_files_path("hyper_track_match.txt")
local module_character_select = require("src/modules/character_select")

-- game state 
require("src/gamestate")

math.randomseed(os.time())

local function unique_id() return tostring(os.time()) .. tostring(math.random(100000, 999999)) end

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
            for i = 1, #value do buffer[#buffer + 1] = encode_json(value[i]) end
            return '[' .. table.concat(buffer, ',') .. ']'
        else
            local keys = {}
            for key, _ in pairs(value) do keys[#keys + 1] = key end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, key in ipairs(keys) do buffer[#buffer + 1] = '"' .. escape_json_string(tostring(key)) .. '":' .. encode_json(value[key]) end
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
                        if type(result[key]) ~= 'table' or not is_array(result[key]) then result[key] = {result[key]} end
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
local last_known_match_uuid = '';
local match_uuid = '';
local match_count = 0;
local total_match_count = 0;
local stat_file
-- match related
local match_just_ended = false
local has_match_transitioned = false
local p1_char
local p2_char
local p1_super
local p2_super
local wins_checked = false
local check_wins_frame_delay = 10
local waiting_to_check_win = false
-- for checking against cpu match
local last_win_count_p1 = 0
local last_win_count_p2 = 0
-- local wasInMatch = false

-- match state
local match_initialized = false
---- meter
local p1_previous_meter = 0; -- for some reason meter set to 70 on character select 
local p1_match_total_meter_gained = 0;
local p2_previous_meter = 0; -- for some reason meter set to 70 on character select 
local p2_match_total_meter_gained = 0;
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
local player_1_win_count = 0;
local player_2_win_count = 0;
local player_1_total_wins = 0; -- just used for display for now.
local player_2_total_wins = 0;
local player_1_total_wins_writing = 0;
local player_2_total_wins_writing = 0;
local data_reset = false; -- this is used to track when we should reset data for wins

local function hyper_reflector_rendering()
    if GLOBAL_isHyperReflectorOnline then
        gui.text(160, 8, player_1_total_wins_writing, util_colors.input_history.unknown1)
        gui.text(221, 8, player_2_total_wins_writing, util_colors.input_history.unknown1)
        -- gui.text(2, 2, 'HYPER-REFLECTOR v030a', util_colors.gui.empty)
    end
end

local function check_in_match()
    local character_select_state = memory.readbyte(0x02015545)
    local match_state = memory.readbyte(0x020154A7);
    -- print(character_select_state)
    -- if match_state == 0 then -- this indicates the emulator was restarted in some way
    --     player_1_win_count = 0
    --     player_2_win_count = 0
    --     return
    -- end

    -- initialize a match
    if character_select_state == 4 and not match_initialized and stat_file == nil then -- this is initial char select and the select state has been reset
        has_match_transitioned = false
        match_just_ended = false
        -- print('match was reset correctly')
        io.open(match_track_file, "w"):close()
        stat_file = io.open(match_track_file, "a")
        if stat_file then
            match_uuid = unique_id()
            stat_file:write('\n -i-game-match', match_count) -- is not registered until the end of the set
            stat_file:write('\n match-uuid:')
            stat_file:write(match_uuid)

        end
        print('resetting data')

        local current_win_count_p1 = memory.readdword(0x02016cd6)
        local current_win_count_p2 = memory.readdword(0x02016cd4)

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

        local should_reset = (current_win_count_p1 == last_win_count_p1 and current_win_count_p2 == last_win_count_p2) or (current_win_count_p1 >= 1 and last_win_count_p1 == 0) or
                                 (current_win_count_p2 >= 1 and last_win_count_p2 == 0) -- this indicates we fought a cpu

        if should_reset then
            print('Detected dummy or CPU match. Resetting win counts.')
            player_1_win_count = 0
            player_2_win_count = 0
        else
            print('Win counts have changed. Keeping win counts.')
            player_1_win_count = current_win_count_p1
            player_2_win_count = current_win_count_p2
        end

        -- Save current values for comparison next time
        last_win_count_p1 = current_win_count_p1
        last_win_count_p2 = current_win_count_p2

        p1_previous_meter = 0
        p2_previous_meter = 0
        match_initialized = true
        wins_checked = false
        waiting_to_check_win = false
        check_wins_frame_delay = 10;
        return
    end

    if match_state == 2 then
        p1_char = memory.readbyte(0x02011387)
        p2_char = memory.readbyte(0x02011388)
        p1_super = memory.readbyte(0x020154D3)
        p2_super = memory.readbyte(0x020154D5)
        -- local p1_wins = memory.readdword(0x02016cd6)
        -- local p2_wins = memory.readdword(0x02016cd4)
        -- player_1_win_count = p1_wins
        -- player_2_win_count = p2_wins
        -- print(p1_char, '---', p2_char)
        -- print(p1_super, '---', p2_super)
    end
    -- local byterange = memory.readbyterange(0x02011388, 12)
    -- local test = memory.readdword(0x02011388)
    -- print(byterange)
    if has_match_transitioned and character_select_state == 5 and match_state == 7 then return 7 end
    if character_select_state == 5 and match_state == 2 then
        -- make sure we are in the match
        has_match_transitioned = true
        return 2
    end
end

local function check_wins()
    local p1_wins = memory.readdword(0x02016cd6)
    local p2_wins = memory.readdword(0x02016cd4)
    print('checkin win counts, this is weird.')
    print('p1 ', p1_wins, player_1_win_count)
    print('p2 ', p2_wins, player_2_win_count)
    if p1_wins > 1000 then
        print('P1 win count overflow detected:', p1_wins)
        p1_wins = 0
    end
    if p2_wins > 1000 then
        print('P2 win count overflow detected:', p2_wins)
        p2_wins = 0
    end

    if p1_wins > player_1_win_count and p1_wins < 100 then
        player_1_total_wins = player_1_total_wins + 1
        player_1_total_wins_writing = player_1_total_wins_writing + 1
        player_2_win_count = 0
        print('player 1 win')
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
        end
        match_just_ended = true
        wins_checked = true
    end

    if p2_wins > player_2_win_count and p2_wins < 100 then
        player_2_total_wins = player_2_total_wins + 1
        player_2_total_wins_writing = player_2_total_wins_writing + 1
        -- reset opponent win count
        player_1_win_count = 0
        print('player 2 win')
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
        end
        match_just_ended = true
        wins_checked = true
    end
    print('resetting the frame delay')
    check_wins_frame_delay = 10
end

local function check_getting_hit()
    local p2_hit_by_normal = memory.readbyte(0x02028861)
    local p2_hit_by_special = memory.readbyte(0x02028863)
    -- local p2_hits_landed_normals = 0
    -- local p2_hits_landed_specials = 0
    -- local p2_hits_landed_supers = 0
    -- local p2_hits_landed_supers_ext = 0
    -- local p1_hits_landed_normals = 0
    -- local p1_hits_landed_specials = 0
    -- local p1_hits_landed_supers = 0
    -- local p1_hits_landed_supers_ext = 0
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

            if p1_current_meter <= p1_previous_meter then p1_previous_meter = p1_current_meter end
            if p2_current_meter <= p2_previous_meter then p2_previous_meter = p2_current_meter end

            local p1_meter_gained = p1_current_meter - p1_previous_meter
            local p2_meter_gained = p2_current_meter - p2_previous_meter
            if p1_meter_gained > 0 then
                p1_match_total_meter_gained = p1_match_total_meter_gained + p1_meter_gained
                p1_previous_meter = p1_current_meter

                stat_file:write('\n p1-meter-gained:')
                stat_file:write(p1_meter_gained)
                stat_file:write('\n p1-total-meter-gained:')
                stat_file:write(p1_match_total_meter_gained)
            end
            if p2_meter_gained > 0 then
                p2_match_total_meter_gained = p2_match_total_meter_gained + p2_meter_gained
                p2_previous_meter = p2_current_meter

                stat_file:write('\n p2-meter-gained:')
                stat_file:write(p2_meter_gained)
                stat_file:write('\n p2-total-meter-gained:')
                stat_file:write(p2_match_total_meter_gained)
            end
        end

        if match_state_key == 7 then
            if not wins_checked and not waiting_to_check_win then
                print("Match ended. Starting frame delay for win check.")
                check_wins_frame_delay = 10 -- or 3 if needed
                waiting_to_check_win = true
            end

            -- Countdown active frame delay
            if check_wins_frame_delay >= 0 then
                check_wins_frame_delay = check_wins_frame_delay - 1
                if check_wins_frame_delay == 0 then
                    print("Executing delayed check_wins after frame delay")
                    -- tilda is for not matching
                    if match_uuid ~= last_known_match_uuid then
                        check_wins()
                        check_wins_frame_delay = -1
                        waiting_to_check_win = false
                        last_known_match_uuid = match_uuid
                    end
                end
            end

            if match_just_ended then
                waiting_to_check_win = false
                check_wins_frame_delay = 2
                p1_match_total_meter_gained = 0
                p1_previous_meter = 0
                p2_match_total_meter_gained = 0
                p2_previous_meter = 0
                match_count = match_count + 1
                total_match_count = total_match_count + 1
                match_initialized = false
                print('Closing file one frame late to capture final meter.')
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

        -- if match_just_ended and match_state_key == 7 then
        --     -- print('resetting all state')
        --     p1_match_total_meter_gained = 0
        --     p1_previous_meter = 0
        --     p2_match_total_meter_gained = 0
        --     p2_previous_meter = 0
        --     match_count = match_count + 1
        --     match_initialized = false
        --     wins_checked = false
        --     print('Closing file one frame late to capture final meter.')
        --     stat_file:close()
        --     stat_file = nil
        --     local front_end_reader = io.open(ext_command_file, "w")
        --     if front_end_reader then
        --         front_end_reader:write('read-tracking-file')
        --         front_end_reader:close()
        --     end
        -- end

        -- if match_state_key == 7 and not wins_checked then
        --     check_wins()
        --     wins_checked = true
        -- end
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
emu.registerbefore(GLOBAL_read_stat_memory) -- Runs after each frame
gui.register(hyper_reflector_rendering)

-- UNCOMMENT below lines  for training mode online
-- emu.registerbefore(third_training.before_frame)
-- gui.register(third_training.on_gui)
-- pressing start should not pause the emulator this is not good =0
