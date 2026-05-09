--- HLS protocol tag constants and attribute list parser.
--
-- @module resty.m3u8.protocol

local type = type
local str_sub = string.sub
local str_find = string.find
local str_byte = string.byte
local str_lower = string.lower
local tab_insert = table.insert
local tab_concat = table.concat
local ngx_re_gsub = ngx.re.gsub


local _M = {
    -- Basic tags
    EXTM3U                   = "#EXTM3U",
    EXTINF                   = "#EXTINF",

    -- Media playlist tags
    EXT_X_TARGETDURATION     = "#EXT-X-TARGETDURATION",
    EXT_X_MEDIA_SEQUENCE     = "#EXT-X-MEDIA-SEQUENCE",
    EXT_X_DISCONTINUITY_SEQUENCE = "#EXT-X-DISCONTINUITY-SEQUENCE",
    EXT_X_ENDLIST            = "#EXT-X-ENDLIST",
    EXT_X_PLAYLIST_TYPE      = "#EXT-X-PLAYLIST-TYPE",
    EXT_X_I_FRAMES_ONLY      = "#EXT-X-I-FRAMES-ONLY",
    EXT_X_IMAGES_ONLY        = "#EXT-X-IMAGES-ONLY",
    EXT_X_INDEPENDENT_SEGMENTS = "#EXT-X-INDEPENDENT-SEGMENTS",

    -- Segment tags
    EXT_X_KEY                = "#EXT-X-KEY",
    EXT_X_MAP                = "#EXT-X-MAP",
    EXT_X_BYTERANGE          = "#EXT-X-BYTERANGE",
    EXT_X_GAP                = "#EXT-X-GAP",
    EXT_X_BITRATE            = "#EXT-X-BITRATE",
    EXT_X_PROGRAM_DATE_TIME  = "#EXT-X-PROGRAM-DATE-TIME",
    EXT_X_DISCONTINUITY      = "#EXT-X-DISCONTINUITY",
    EXT_X_DATERANGE          = "#EXT-X-DATERANGE",

    -- Master playlist tags
    EXT_X_STREAM_INF         = "#EXT-X-STREAM-INF",
    EXT_X_I_FRAME_STREAM_INF = "#EXT-X-I-FRAME-STREAM-INF",
    EXT_X_IMAGE_STREAM_INF   = "#EXT-X-IMAGE-STREAM-INF",
    EXT_X_MEDIA              = "#EXT-X-MEDIA",
    EXT_X_SESSION_DATA       = "#EXT-X-SESSION-DATA",
    EXT_X_SESSION_KEY        = "#EXT-X-SESSION-KEY",
    EXT_X_CONTENT_STEERING   = "#EXT-X-CONTENT-STEERING",

    -- Media/playlist level tags
    EXT_X_VERSION            = "#EXT-X-VERSION",
    EXT_X_ALLOW_CACHE        = "#EXT-X-ALLOW-CACHE",
    EXT_X_START              = "#EXT-X-START",
    EXT_X_SERVER_CONTROL     = "#EXT-X-SERVER-CONTROL",
    EXT_X_PART_INF           = "#EXT-X-PART-INF",
    EXT_X_PART               = "#EXT-X-PART",
    EXT_X_PRELOAD_HINT       = "#EXT-X-PRELOAD-HINT",
    EXT_X_RENDITION_REPORT   = "#EXT-X-RENDITION-REPORT",
    EXT_X_SKIP               = "#EXT-X-SKIP",
    EXT_X_TILES              = "#EXT-X-TILES",
    EXT_X_DEFINE             = "#EXT-X-DEFINE",

    -- Cue / SCTE35 tags
    EXT_X_CUE_OUT            = "#EXT-X-CUE-OUT",
    EXT_X_CUE_OUT_CONT       = "#EXT-X-CUE-OUT-CONT",
    EXT_X_CUE_IN             = "#EXT-X-CUE-IN",
    EXT_X_CUE_SPAN           = "#EXT-X-CUE-SPAN",
    EXT_OATCLS_SCTE35        = "#EXT-OATCLS-SCTE35",
    EXT_X_ASSET              = "#EXT-X-ASSET",
}


--- Replace all occurrences of old_str with new_str (plain text, JIT-friendly).
local function replace_literal(s, old_str, new_str)
    local old_len = #old_str
    if old_len == 0 then
        return s
    end
    local result = {}
    local pos = 1
    while true do
        local p = str_find(s, old_str, pos, true)
        if not p then
            tab_insert(result, str_sub(s, pos))
            break
        end
        tab_insert(result, str_sub(s, pos, p - 1))
        tab_insert(result, new_str)
        pos = p + old_len
    end
    return tab_concat(result)
end


--- Normalize an attribute name: lowercase and replace hyphens with underscores.
-- e.g., "PROGRAM-ID" → "program_id"
local function normalize_attribute(attribute)
    local s = str_lower(attribute)
    s = replace_literal(s, "-", "_")
    return s
end


--- Remove surrounding double or single quotes from a string.
local function remove_quotes(s)
    if s == nil then
        return nil
    end
    local len = #s
    if len < 2 then
        return s
    end
    local first = str_sub(s, 1, 1)
    local last = str_sub(s, len, len)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return str_sub(s, 2, len - 1)
    end
    return s
end


--- Try to coerce a string value to number.
local function try_number(s)
    if s == nil then
        return nil
    end
    local n = tonumber(s)
    if n ~= nil then
        return n
    end
    -- Check for hex format like 0xABCD
    if str_sub(s, 1, 2) == "0x" or str_sub(s, 1, 2) == "0X" then
        return tonumber(s)
    end
    return s
end


--- Parse an HLS attribute list string into a table of key-value pairs.
--
-- Handles quoted strings containing commas and escaped quotes.
-- Attribute keys are normalized (lowercase, hyphens→underscores).
-- Values are automatically unquoted and numeric strings are coerced to numbers.
--
-- @param  line  string  the attribute list portion after the tag colon
-- @return table  {attr_name = value, ...}
function _M.parse_attributes(line)
    if line == nil or line == "" then
        return {}
    end

    local result = {}
    local len = #line
    local i = 1

    while i <= len do
        -- Skip leading whitespace
        while i <= len and (str_byte(line, i) == 32 or str_byte(line, i) == 9) do
            i = i + 1
        end
        if i > len then
            break
        end

        -- Read key: everything up to '='
        local key_start = i
        while i <= len and str_byte(line, i) ~= 61 do -- 61 is '='
            i = i + 1
        end
        local key = str_sub(line, key_start, i - 1)
        if key == "" then
            break
        end
        key = normalize_attribute(key)

        -- Skip the '='
        i = i + 1
        if i > len then
            result[key] = ""
            break
        end

        -- Read value: handle quoted strings with potential embedded commas
        local value
        local ch = str_byte(line, i)
        if ch == 34 then -- double quote (")
            local val_start = i + 1
            i = i + 1
            while i <= len do
                local b = str_byte(line, i)
                if b == 34 then -- closing quote
                    -- Check for escaped quote ("")
                    if i + 1 <= len and str_byte(line, i + 1) == 34 then
                        i = i + 2  -- skip both quotes, continue
                    else
                        value = str_sub(line, val_start, i - 1)
                        value = replace_literal(value, '""', '"') -- unescape
                        i = i + 1
                        break
                    end
                else
                    i = i + 1
                end
            end
            if value == nil then
                value = str_sub(line, val_start, i - 1)
            end
        elseif ch == 39 then -- single quote (')
            local val_start = i + 1
            i = i + 1
            while i <= len do
                if str_byte(line, i) == 39 then
                    value = str_sub(line, val_start, i - 1)
                    value = replace_literal(value, "''", "'") -- unescape
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            if value == nil then
                value = str_sub(line, val_start, i - 1)
            end
        else
            -- Unquoted value: read until comma or end
            local val_start = i
            while i <= len and str_byte(line, i) ~= 44 do -- 44 is ','
                i = i + 1
            end
            value = str_sub(line, val_start, i - 1)
        end

        -- Coerce hex strings (like IV=0xABCD) to remain as strings,
        -- but plain numbers to number type
        if type(value) == "string" then
            local stripped = ngx_re_gsub(value, [[^\s+|\s+$]], "", "jo")
            if str_sub(stripped, 1, 2) == "0x" or str_sub(stripped, 1, 2) == "0X" then
                value = stripped  -- keep hex as string
            else
                value = try_number(stripped)
            end
        end

        if key ~= "" then
            result[key] = value
        end

        -- Skip the comma separator
        while i <= len and (str_byte(line, i) == 44 or str_byte(line, i) == 32 or str_byte(line, i) == 9) do
            i = i + 1
        end
    end

    return result
end


--- Remove quotes from string values.
function _M.remove_quotes(s)
    return remove_quotes(s)
end


--- Normalize attribute name.
function _M.normalize_attribute(a)
    return normalize_attribute(a)
end


return _M
