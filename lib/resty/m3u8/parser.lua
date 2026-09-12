--- HLS m3u8 playlist parser.
--
-- Parses raw m3u8 text into a structured data table.
--
-- @module resty.m3u8.parser

local type = type
local str_find = string.find
local str_sub = string.sub
local str_upper = string.upper
local tonumber = tonumber
local tab_insert = table.insert
local tab_concat = table.concat
local os_time = os.time
local os_date = os.date
local tab_clone = require("table.clone")
local ngx_re_gsub = ngx.re.gsub
local protocol = require("resty.m3u8.protocol")

local _M = {}


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------


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


--- Split content into individual lines (handles \r\n, \n, \r).
local function string_to_lines(content)
    if content == nil or content == "" then
        return {}
    end
    -- Normalize line endings
    local s = replace_literal(content, "\r\n", "\n")
    s = replace_literal(s, "\r", "\n")
    -- Split using str_find (plain mode, JIT-compatible)
    local lines = {}
    local pos = 1
    local slen = #s
    while pos <= slen do
        local e = str_find(s, "\n", pos, true)
        if e then
            tab_insert(lines, str_sub(s, pos, e - 1))
            pos = e + 1
        else
            tab_insert(lines, str_sub(s, pos))
            break
        end
    end
    return lines
end


--- Strip whitespace from both ends of a string (uses ngx.re.gsub, JIT-friendly).
local function strip(s)
    if s == nil then
        return nil
    end
    return ngx_re_gsub(s, [[^\s+|\s+$]], "", "jo")
end


--- Parse ISO 8601 date string to a timestamp (seconds since epoch).
-- Uses manual parsing with string.find (plain mode) to be LuaJIT-friendly.
local function parse_iso8601(s)
    if s == nil then
        return nil
    end
    -- Format: YYYY-MM-DDTHH:MM:SS
    local hyphen1 = str_find(s, "-", 1, true)
    local hyphen2 = hyphen1 and str_find(s, "-", hyphen1 + 1, true)
    local t_pos = hyphen2 and str_find(s, "T", hyphen2 + 1, true)
    local colon1 = t_pos and str_find(s, ":", t_pos + 1, true)
    local colon2 = colon1 and str_find(s, ":", colon1 + 1, true)
    if not colon2 then
        return nil
    end
    return os_time({
        year = tonumber(str_sub(s, 1, hyphen1 - 1)),
        month = tonumber(str_sub(s, hyphen1 + 1, hyphen2 - 1)),
        day = tonumber(str_sub(s, hyphen2 + 1, t_pos - 1)),
        hour = tonumber(str_sub(s, t_pos + 1, colon1 - 1)),
        min = tonumber(str_sub(s, colon1 + 1, colon2 - 1)),
        sec = tonumber(str_sub(s, colon2 + 1)),
    })
end


--- Format a timestamp to ISO 8601 string.
local function format_iso8601(ts)
    return os_date("!%Y-%m-%dT%H:%M:%SZ", ts)
end


--- Convert YES/NO string to boolean.
local function yesno_to_bool(s)
    if s == nil then
        return nil
    end
    local upper = str_upper(s)
    if upper == "YES" then
        return true
    elseif upper == "NO" then
        return false
    end
    return s
end


--- Parse a byterange string like "1234@5678" or "1234".
local function parse_byterange_string(s)
    if s == nil then
        return nil
    end
    local at_pos = str_find(s, "@", 1, true)
    if at_pos then
        return {
            length = tonumber(str_sub(s, 1, at_pos - 1)) or 0,
            offset = tonumber(str_sub(s, at_pos + 1)),
        }
    else
        return {
            length = tonumber(s) or 0,
        }
    end
end


--- Finalize a pending segment and append it to the segments list.
local function finalize_segment(state, data)
    local seg = state.segment
    if not seg then
        return
    end

    -- Attach carry-forward state
    if state.current_key then
        seg.key = tab_clone(state.current_key)
    end
    if state.current_map then
        seg.map = tab_clone(state.current_map)
    end
    if state.current_program_date_time then
        seg.program_date_time = state.current_program_date_time
        local ts = parse_iso8601(state.current_program_date_time)
        if ts and seg.duration then
            state.current_program_date_time = format_iso8601(ts + seg.duration)
        else
            state.current_program_date_time = nil
        end
    end
    if state.discontinuity then
        seg.discontinuity = true
        state.discontinuity = false
    end
    if state.gap then
        seg.gap = true
        state.gap = false
    end

    -- Attach cue-in flag
    if state.cue_in then
        seg.cue_in = true
        state.cue_in = false
    end

    -- Attach SCTE35 / asset metadata
    if state.scte35 then
        seg.scte35 = state.scte35
        seg.scte35_duration = state.scte35_duration
        seg.scte35_elapsedtime = state.scte35_elapsedtime
        if state.cue_out_explicitly_duration then
            seg.cue_out_explicitly_duration = state.cue_out_explicitly_duration
        end
        state.scte35 = nil
        state.scte35_duration = nil
        state.scte35_elapsedtime = nil
        state.cue_out_explicitly_duration = nil
    end

    if state.oatcls_scte35 then
        seg.oatcls_scte35 = state.oatcls_scte35
        state.oatcls_scte35 = nil
    end

    if state.asset_metadata then
        seg.asset_metadata = state.asset_metadata
        state.asset_metadata = nil
    end

    -- Attach cue_out flag (persists until CUE-IN)
    if state.cue_out then
        seg.cue_out = true
        seg.cue_out_start = state.cue_out_start
        if state.cue_out_explicitly_duration then
            seg.cue_out_explicitly_duration = state.cue_out_explicitly_duration
        end
        state.cue_out_start = false
    end

    -- Attach dateranges accumulated during this segment
    if state.current_dateranges and #state.current_dateranges > 0 then
        seg.dateranges = {}
        for _, dr in ipairs(state.current_dateranges) do
            tab_insert(seg.dateranges, dr)
        end
        state.current_dateranges = {}
    end

    -- Attach parts accumulated
    if state.current_parts and #state.current_parts > 0 then
        seg.parts = {}
        for _, p in ipairs(state.current_parts) do
            tab_insert(seg.parts, p)
        end
        state.current_parts = {}
    end

    -- Attach bitrate
    if state.current_bitrate then
        seg.bitrate = state.current_bitrate
        state.current_bitrate = nil
    end

    tab_insert(data.segments, seg)
    state.segment = nil
    state.expecting_uri = false
end


--------------------------------------------------------------------------------
-- Tag Handler Functions
--------------------------------------------------------------------------------


local function parse_extm3u(state, data, value)
    -- No-op, just marks file as m3u8
end


local function parse_extinf(state, data, value, strict, line_num)
    if not value then
        return
    end

    local duration, title
    local comma_pos = str_find(value, ",", 1, true)
    if comma_pos then
        duration = tonumber(str_sub(value, 1, comma_pos - 1))
        title = str_sub(value, comma_pos + 1)
    else
        if strict then
            state.error = "syntax error on line " .. tostring(line_num) .. ": #EXTINF without comma"
            return
        end
        duration = tonumber(value)
        title = nil
    end

    -- EXT-X-PART and EXT-X-BYTERANGE may have created a pending segment
    -- already.  Preserve that state when EXTINF supplies its duration/title.
    if not state.segment then
        state.segment = {
            uri = nil,
            discontinuity = false,
            gap = false,
        }
    end
    state.segment.duration = duration or 0
    state.segment.title = title
    state.expecting_uri = "segment"
end


local function parse_targetduration(state, data, value)
    if value then
        data.target_duration = tonumber(value)
    end
end


local function parse_media_sequence(state, data, value)
    if value then
        data.media_sequence = tonumber(value)
    end
end


local function parse_discontinuity_sequence(state, data, value)
    if value then
        data.discontinuity_sequence = tonumber(value)
    end
end


local function parse_endlist(state, data, value)
    data.is_endlist = true
end


local function parse_playlist_type(state, data, value)
    if value then
        data.playlist_type = strip(value)
    end
end


local function parse_i_frames_only(state, data, value)
    data.is_i_frames_only = true
end


local function parse_images_only(state, data, value)
    data.is_images_only = true
end


local function parse_independent_segments(state, data, value)
    data.is_independent_segments = true
end


local function parse_version(state, data, value)
    if value then
        data.version = tonumber(value)
    end
end


local function parse_allow_cache(state, data, value)
    if value then
        data.allow_cache = strip(value)
    end
end


local function parse_key(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local key_data = {
        method = attrs.method or "NONE",
        uri = attrs.uri,
        iv = attrs.iv,
        keyformat = attrs.keyformat,
        keyformatversions = attrs.keyformatversions,
    }

    -- Store in state for carry-forward to subsequent segments
    state.current_key = key_data

    -- Also add to data.keys list
    tab_insert(data.keys, key_data)
end


local function parse_map(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local byterange = nil
    if attrs.byterange then
        byterange = parse_byterange_string(attrs.byterange)
    end

    local map_data = {
        uri = attrs.uri,
        byterange = byterange,
    }

    state.current_map = map_data
    data.segment_map = map_data
end


local function parse_byterange(state, data, value)
    if not value then
        return
    end

    local br = parse_byterange_string(value)
    if not state.segment then
        -- Applied to a segment that will be created by the next EXTINF
        state.segment = { duration = 0, title = nil, uri = nil, discontinuity = false, gap = false }
        state.expecting_uri = "segment"
    end
    state.segment.byterange = br
end


local function parse_gap(state, data, value)
    state.gap = true
end


local function parse_bitrate(state, data, value)
    if value then
        state.current_bitrate = tonumber(value)
    end
end


local function parse_program_date_time(state, data, value)
    if value then
        local dt_str = strip(value)
        if not data.program_date_time then
            data.program_date_time = dt_str
        end
        if state.segment then
            state.segment.program_date_time = dt_str
        else
            state.current_program_date_time = dt_str
            data.program_date_time = dt_str
        end
    end
end


local function parse_discontinuity(state, data, value)
    state.discontinuity = true
end


local function parse_cue_in(state, data, value)
    state.cue_in = true
    state.cue_out = false
end


local function parse_cue_span(state, data, value)
    state.cue_out = true
    state.cue_out_start = true
end


local function parse_stream_inf(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)

    local resolution = attrs.resolution
    if type(resolution) == "number" then
        resolution = tostring(resolution)
    end

    local stream_info = {
        bandwidth = attrs.bandwidth or 0,
        average_bandwidth = attrs.average_bandwidth,
        codecs = attrs.codecs,
        resolution = resolution,
        frame_rate = attrs.frame_rate,
        audio = attrs.audio,
        video = attrs.video,
        subtitles = attrs.subtitles,
        closed_captions = attrs.closed_captions,
        program_id = attrs.program_id,
        hdcp_level = attrs.hdcp_level,
        video_range = attrs.video_range,
        pathway_id = attrs.pathway_id,
        stable_variant_id = attrs.stable_variant_id,
        req_video_layout = attrs.req_video_layout,
        name = attrs.name,
    }

    state.playlist = stream_info
    state.expecting_uri = "playlist"
    data.is_variant = true
end


local function parse_i_frame_stream_inf(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local uri = attrs.uri or ""

    local stream_info = {
        bandwidth = attrs.bandwidth or 0,
        average_bandwidth = attrs.average_bandwidth,
        codecs = attrs.codecs,
        resolution = attrs.resolution,
        frame_rate = attrs.frame_rate,
        video = attrs.video,
        program_id = attrs.program_id,
        hdcp_level = attrs.hdcp_level,
        video_range = attrs.video_range,
        pathway_id = attrs.pathway_id,
        stable_variant_id = attrs.stable_variant_id,
        req_video_layout = attrs.req_video_layout,
    }

    tab_insert(data.iframe_playlists, {
        uri = uri,
        stream_info = stream_info,
    })

    data.is_variant = true
end


local function parse_image_stream_inf(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local uri = attrs.uri or ""

    local stream_info = {
        bandwidth = attrs.bandwidth or 0,
        average_bandwidth = attrs.average_bandwidth,
        codecs = attrs.codecs,
        resolution = attrs.resolution,
        frame_rate = attrs.frame_rate,
        program_id = attrs.program_id,
        hdcp_level = attrs.hdcp_level,
        video_range = attrs.video_range,
        pathway_id = attrs.pathway_id,
    }

    tab_insert(data.image_playlists, {
        uri = uri,
        stream_info = stream_info,
    })

    data.is_variant = true
end


local function parse_media(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)

    local media_data = {
        media_type = attrs.type or "",
        group_id = attrs.group_id or "",
        name = attrs.name or "",
        language = attrs.language,
        assoc_language = attrs.assoc_language,
        uri = attrs.uri,
        default = yesno_to_bool(attrs.default) == true,
        autoselect = yesno_to_bool(attrs.autoselect) == true,
        forced = yesno_to_bool(attrs.forced) == true,
        instream_id = attrs.instream_id,
        characteristics = attrs.characteristics,
        channels = attrs.channels,
        stable_rendition_id = attrs.stable_rendition_id,
    }

    tab_insert(data.media, media_data)
end


local function parse_session_data(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    tab_insert(data.session_data, {
        data_id = attrs.data_id or "",
        value = attrs.value,
        uri = attrs.uri,
        language = attrs.language,
    })
end


local function parse_session_key(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    tab_insert(data.session_keys, {
        method = attrs.method or "NONE",
        uri = attrs.uri,
        iv = attrs.iv,
        keyformat = attrs.keyformat,
        keyformatversions = attrs.keyformatversions,
    })
end


local function parse_start(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.start = {
        time_offset = attrs.time_offset or 0,
        precise = yesno_to_bool(attrs.precise) == true,
    }
end


local function parse_server_control(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.server_control = {
        can_skip_until = attrs.can_skip_until,
        can_block_reload = yesno_to_bool(attrs.can_block_reload) == true,
        hold_back = attrs.hold_back,
        part_hold_back = attrs.part_hold_back,
        can_skip_dateranges = yesno_to_bool(attrs.can_skip_dateranges) == true,
    }
end


local function parse_part_inf(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.part_inf = {
        part_target = attrs.part_target,
    }
end


local function parse_part(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local byterange = nil
    if attrs.byterange then
        byterange = parse_byterange_string(attrs.byterange)
    end

    local part = {
        uri = attrs.uri or "",
        duration = attrs.duration or 0,
        independent = yesno_to_bool(attrs.independent) == true,
        gap = yesno_to_bool(attrs.gap) == true,
        byterange = byterange,
    }

    if not state.current_parts then
        state.current_parts = {}
    end
    tab_insert(state.current_parts, part)

    -- If no segment exists yet, create a placeholder
    if not state.segment then
        state.segment = { duration = 0, title = nil, uri = nil, discontinuity = false, gap = false }
    end
end


local function parse_skip(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.skip = {
        skipped_segments = attrs.skipped_segments or 0,
        recently_removed_dateranges = attrs.recently_removed_dateranges,
    }
end


local function parse_preload_hint(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.preload_hint = {
        hint_type = attrs.type or "",
        uri = attrs.uri or "",
        byterange_start = attrs.byterange_start,
        byterange_length = attrs.byterange_length,
    }
end


local function parse_rendition_report(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    tab_insert(data.rendition_reports, {
        uri = attrs.uri or "",
        last_msn = attrs.last_msn,
        last_part = attrs.last_part,
    })
end


local function parse_daterange(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    local x_attrs = {}

    local standard_keys = {
        id = true, class = true, start_date = true, end_date = true,
        duration = true, planned_duration = true,
        scte35_cmd = true, scte35_out = true, scte35_in = true,
        end_on_next = true,
    }

    for k, v in pairs(attrs) do
        if not standard_keys[k] then
            if str_sub(k, 1, 2) == "x_" then
                x_attrs[str_sub(k, 3)] = v
            end
        end
    end

    local daterange = {
        id = attrs.id or "",
        class = attrs.class,
        start_date = attrs.start_date or "",
        end_date = attrs.end_date,
        duration = attrs.duration,
        planned_duration = attrs.planned_duration,
        scte35_cmd = attrs.scte35_cmd,
        scte35_out = attrs.scte35_out,
        scte35_in = attrs.scte35_in,
        end_on_next = yesno_to_bool(attrs.end_on_next) == true,
        x_attributes = x_attrs,
    }

    if not state.current_dateranges then
        state.current_dateranges = {}
    end
    tab_insert(state.current_dateranges, daterange)
end


local function parse_content_steering(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.content_steering = {
        server_uri = attrs.server_uri or "",
        pathway_id = attrs.pathway_id,
    }
end


local function parse_tiles(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    data.tiles = {
        resolution = attrs.resolution or "",
        layout = attrs.layout or "",
        duration = attrs.duration or 0,
        uri = attrs.uri,
    }
end


local function parse_define(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    if not data.defines then
        data.defines = {}
    end
    tab_insert(data.defines, {
        name = attrs.name,
        value = attrs.value,
        import = attrs.import,
    })
end


local function parse_cueout(state, data, value)
    if not value then
        return
    end
    state.cue_out = true

    local attrs = protocol.parse_attributes(value)
    if attrs.duration then
        state.cue_out_explicitly_duration = attrs.duration
    end
    if attrs.scte35 then
        state.scte35 = attrs.scte35
    end
end


local function parse_cueout_cont(state, data, value)
    if not value then
        return
    end

    local attrs = protocol.parse_attributes(value)
    state.scte35_elapsedtime = attrs.elapsedtime
    state.scte35_duration = attrs.duration
    state.scte35 = attrs.scte35
    state.cue_out = true
end


local function parse_oatcls_scte35(state, data, value)
    if value then
        state.oatcls_scte35 = strip(value)
    end
end


local function parse_asset(state, data, value)
    if value then
        state.asset_metadata = strip(value)
        state.cue_out = true
    end
end


--------------------------------------------------------------------------------
-- Tag Dispatch Table
--------------------------------------------------------------------------------

local tag_handlers = {
    [protocol.EXTM3U]                     = parse_extm3u,
    [protocol.EXTINF]                     = parse_extinf,
    [protocol.EXT_X_TARGETDURATION]       = parse_targetduration,
    [protocol.EXT_X_MEDIA_SEQUENCE]       = parse_media_sequence,
    [protocol.EXT_X_DISCONTINUITY_SEQUENCE] = parse_discontinuity_sequence,
    [protocol.EXT_X_ENDLIST]              = parse_endlist,
    [protocol.EXT_X_PLAYLIST_TYPE]        = parse_playlist_type,
    [protocol.EXT_X_I_FRAMES_ONLY]        = parse_i_frames_only,
    [protocol.EXT_X_IMAGES_ONLY]          = parse_images_only,
    [protocol.EXT_X_INDEPENDENT_SEGMENTS] = parse_independent_segments,
    [protocol.EXT_X_VERSION]              = parse_version,
    [protocol.EXT_X_ALLOW_CACHE]          = parse_allow_cache,
    [protocol.EXT_X_KEY]                  = parse_key,
    [protocol.EXT_X_MAP]                  = parse_map,
    [protocol.EXT_X_BYTERANGE]            = parse_byterange,
    [protocol.EXT_X_GAP]                  = parse_gap,
    [protocol.EXT_X_BITRATE]              = parse_bitrate,
    [protocol.EXT_X_PROGRAM_DATE_TIME]    = parse_program_date_time,
    [protocol.EXT_X_DISCONTINUITY]        = parse_discontinuity,
    [protocol.EXT_X_CUE_IN]               = parse_cue_in,
    [protocol.EXT_X_CUE_SPAN]             = parse_cue_span,
    [protocol.EXT_X_CUE_OUT]              = parse_cueout,
    [protocol.EXT_X_CUE_OUT_CONT]         = parse_cueout_cont,
    [protocol.EXT_OATCLS_SCTE35]          = parse_oatcls_scte35,
    [protocol.EXT_X_ASSET]                = parse_asset,
    [protocol.EXT_X_STREAM_INF]           = parse_stream_inf,
    [protocol.EXT_X_I_FRAME_STREAM_INF]   = parse_i_frame_stream_inf,
    [protocol.EXT_X_IMAGE_STREAM_INF]     = parse_image_stream_inf,
    [protocol.EXT_X_MEDIA]                = parse_media,
    [protocol.EXT_X_SESSION_DATA]         = parse_session_data,
    [protocol.EXT_X_SESSION_KEY]          = parse_session_key,
    [protocol.EXT_X_START]                = parse_start,
    [protocol.EXT_X_SERVER_CONTROL]       = parse_server_control,
    [protocol.EXT_X_PART_INF]             = parse_part_inf,
    [protocol.EXT_X_PART]                 = parse_part,
    [protocol.EXT_X_PRELOAD_HINT]         = parse_preload_hint,
    [protocol.EXT_X_RENDITION_REPORT]     = parse_rendition_report,
    [protocol.EXT_X_SKIP]                 = parse_skip,
    [protocol.EXT_X_DATERANGE]            = parse_daterange,
    [protocol.EXT_X_CONTENT_STEERING]     = parse_content_steering,
    [protocol.EXT_X_TILES]                = parse_tiles,
    [protocol.EXT_X_DEFINE]               = parse_define,
}


--------------------------------------------------------------------------------
-- Main Parse Function
--------------------------------------------------------------------------------


--- Parse an m3u8 content string into a structured data table.
--
-- @param  content  string  raw m3u8 playlist text
-- @param  strict   boolean (optional, default true) error on unknown tags
-- @return table    parsed data table
-- @return nil, error_message on failure
function _M.parse(content, strict)
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end

    if strict == nil then
        -- The reference m3u8 package is permissive by default; callers opt in
        -- to validation with the strict argument.
        strict = false
    end

    local lines = string_to_lines(content)
    if #lines == 0 then
        return nil, "empty content"
    end

    -- First line must be #EXTM3U
    local first_line = strip(lines[1])
    if first_line ~= protocol.EXTM3U then
        return nil, "content must start with #EXTM3U"
    end

    -- Initialize output data table
    local data = {
        media_sequence = 0,
        is_variant = false,
        is_endlist = false,
        is_i_frames_only = false,
        is_independent_segments = false,
        is_images_only = false,
        playlist_type = nil,
        target_duration = nil,
        version = nil,
        allow_cache = nil,
        program_date_time = nil,
        discontinuity_sequence = nil,
        playlists = {},
        segments = {},
        iframe_playlists = {},
        image_playlists = {},
        media = {},
        keys = {},
        session_keys = {},
        session_data = {},
        rendition_reports = {},
        dateranges = {},
        defines = {},
        skip = nil,
        segment_map = nil,
        part_inf = nil,
        start = nil,
        server_control = nil,
        preload_hint = nil,
        content_steering = nil,
        tiles = nil,
    }

    -- Parser state
    local state = {
        expecting_uri = false,
        current_key = nil,
        current_map = nil,
        segment = nil,
        playlist = nil,
        discontinuity = false,
        gap = false,
        cue_out = false,
        cue_out_start = false,
        cue_in = false,
        cue_out_explicitly_duration = nil,
        scte35 = nil,
        scte35_duration = nil,
        scte35_elapsedtime = nil,
        oatcls_scte35 = nil,
        asset_metadata = nil,
        current_program_date_time = nil,
        current_bitrate = nil,
        current_parts = nil,
        current_dateranges = nil,
    }

    for line_num = 2, #lines do
        local line = strip(lines[line_num])

        -- Skip empty lines
        if line == "" then
            goto continue
        end

        local ch = str_sub(line, 1, 1)

        if ch ~= "#" then
            -- URI line (only consumed when expecting one)
            if state.expecting_uri == "segment" then
                if state.segment then
                    state.segment.uri = line
                    finalize_segment(state, data)
                end
            elseif state.expecting_uri == "playlist" then
                if state.playlist then
                    tab_insert(data.playlists, {
                        uri = line,
                        stream_info = state.playlist,
                    })
                    state.playlist = nil
                end
                state.expecting_uri = false
            end
            -- Lines not expected as URI are invalid in strict mode.
            if strict then
                return nil, "syntax error on line " .. tostring(line_num) .. ": " .. line
            end

        elseif str_sub(line, 1, 4) == "#EXT" then
            -- Extract tag name (before colon) and value (after colon)
            local colon_pos = str_find(line, ":", 1, true)
            local tag, value
            if colon_pos then
                tag = str_sub(line, 1, colon_pos - 1)
                value = str_sub(line, colon_pos + 1)
            else
                tag = line
                value = nil
            end

            local handler = tag_handlers[tag]
            if handler then
                handler(state, data, value, strict, line_num)
                if state.error then
                    return nil, state.error
                end
            elseif strict then
                return nil, "unknown tag on line " .. tostring(line_num) .. ": " .. tag
            end

        else
            -- Non-EXT comment line (#...), skip silently
        end

        ::continue::
    end

    -- Finalize any pending segment at EOF
    if state.segment and (state.segment.uri or state.current_parts) then
        finalize_segment(state, data)
    end

    return data
end


return _M
