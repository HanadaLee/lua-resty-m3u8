--- HLS domain model classes with dumps() serialization.
--
-- @module resty.m3u8.model

local type = type
local str_find = string.find
local str_sub = string.sub
local str_byte = string.byte
local str_upper = string.upper
local str_format = string.format
local math_floor = math.floor
local tostring = tostring
local tab_insert = table.insert
local tab_sort = table.sort
local tab_concat = table.concat
local ngx_re_gsub = ngx.re.gsub
local protocol = require("resty.m3u8.protocol")


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


--- Denormalize an attribute name: underscores → hyphens, uppercase.
-- e.g., "program_id" → "PROGRAM-ID"
local function denormalize_attribute(attribute)
    local s = replace_literal(attribute, "_", "-")
    return str_upper(s)
end


--- Check if a string value needs quoting (contains comma, quote, or leading/trailing whitespace).
local function needs_quoting(v)
    if type(v) ~= "string" then
        return false
    end
    -- Plain mode str_find for JIT compatibility
    if str_find(v, ",", 1, true) or str_find(v, '"', 1, true) or str_find(v, "'", 1, true) then
        return true
    end
    -- Check leading/trailing whitespace
    local b = str_byte(v, 1)
    if b == 32 or b == 9 then
        return true
    end
    b = str_byte(v, #v)
    if b == 32 or b == 9 then
        return true
    end
    return false
end


--- Format a single HLS attribute as KEY=VALUE with proper quoting.
-- @param key         string  attribute name (snake_case, will be denormalized)
-- @param value       any     attribute value
-- @param force_quote boolean if true, always quote the value
-- @return string or nil if value is nil
local function _fmt_attr(key, value, force_quote)
    if value == nil then
        return nil
    end

    local hls_key = denormalize_attribute(key)

    if type(value) == "boolean" then
        return hls_key .. "=" .. (value and "YES" or "NO")
    end

    if type(value) == "number" then
        return hls_key .. "=" .. tostring(value)
    end

    local sv = tostring(value)

    if force_quote or needs_quoting(sv) or sv == "" then
        return hls_key .. "=\"" .. sv .. "\""
    end

    return hls_key .. "=" .. sv
end


--- Format a string for HLS EXTINF duration (precise decimal rendering).
local function number_to_string(n)
    if n == nil then
        return "0"
    end
    if n == math_floor(n) then
        return str_format("%d", n)
    end
    return ngx_re_gsub(str_format("%.6f", n), [[\.?0+$]], "", "jo")
end


--------------------------------------------------------------------------------
-- ByteRange
--------------------------------------------------------------------------------

local ByteRange = {}

--- Create a new ByteRange.
-- @param opts.length  number  byte range length
-- @param opts.offset  number  byte range offset (optional)
function ByteRange.new(opts)
    opts = opts or {}
    local obj = {
        length = opts.length or 0,
        offset = opts.offset,
    }
    obj.dumps = ByteRange.dumps
    return obj
end

function ByteRange:dumps()
    if self.offset then
        return str_format("%d@%d", self.length, self.offset)
    end
    return tostring(self.length)
end


--------------------------------------------------------------------------------
-- Key
--------------------------------------------------------------------------------

local Key = {}

--- Create a new Key.
-- @param opts.method             string  encryption method (NONE, AES-128, SAMPLE-AES)
-- @param opts.uri                string  key file URI (optional)
-- @param opts.iv                 string  initialization vector (optional, hex)
-- @param opts.keyformat          string  key format (optional)
-- @param opts.keyformatversions  string  key format versions (optional)
function Key.new(opts)
    opts = opts or {}
    local obj = {
        method = opts.method or "NONE",
        uri = opts.uri,
        iv = opts.iv,
        keyformat = opts.keyformat,
        keyformatversions = opts.keyformatversions,
    }
    obj.dumps = Key.dumps
    obj.tag = protocol.EXT_X_KEY
    return obj
end

function Key:dumps()
    local attrs = {}
    tab_insert(attrs, _fmt_attr("method", self.method))

    if self.uri then
        tab_insert(attrs, _fmt_attr("uri", self.uri, true))
    end
    if self.iv then
        tab_insert(attrs, _fmt_attr("iv", self.iv))
    end
    if self.keyformat then
        tab_insert(attrs, _fmt_attr("keyformat", self.keyformat, true))
    end
    if self.keyformatversions then
        tab_insert(attrs, _fmt_attr("keyformatversions", self.keyformatversions, true))
    end

    return self.tag .. ":" .. tab_concat(attrs, ",")
end


--------------------------------------------------------------------------------
-- Map (InitializationSection / EXT-X-MAP)
--------------------------------------------------------------------------------

local Map = {}

--- Create a new Map.
-- @param opts.uri       string  init file URI
-- @param opts.byterange table   ByteRange object (optional)
function Map.new(opts)
    opts = opts or {}

    -- Convert raw byterange data to ByteRange object
    local byterange = opts.byterange
    if type(byterange) == "table" and not byterange.dumps then
        byterange = ByteRange.new(byterange)
    end

    local obj = {
        uri = opts.uri or "",
        byterange = byterange,
    }
    obj.dumps = Map.dumps
    obj.tag = protocol.EXT_X_MAP
    return obj
end

function Map:dumps()
    local attrs = {}
    tab_insert(attrs, _fmt_attr("uri", self.uri, true))
    if self.byterange then
        tab_insert(attrs, _fmt_attr("byterange", self.byterange:dumps(), true))
    end
    return self.tag .. ":" .. tab_concat(attrs, ",")
end


--------------------------------------------------------------------------------
-- StreamInfo
--------------------------------------------------------------------------------

local StreamInfo = {}

--- Create a new StreamInfo.
function StreamInfo.new(opts)
    opts = opts or {}
    local obj = {
        bandwidth = opts.bandwidth or 0,
        average_bandwidth = opts.average_bandwidth,
        codecs = opts.codecs,
        resolution = opts.resolution,       -- string like "1920x1080"
        frame_rate = opts.frame_rate,
        audio = opts.audio,                 -- group-id string
        video = opts.video,                 -- group-id string
        subtitles = opts.subtitles,         -- group-id string
        closed_captions = opts.closed_captions, -- "NONE" or group-id
        program_id = opts.program_id,
        hdcp_level = opts.hdcp_level,
        video_range = opts.video_range,
        pathway_id = opts.pathway_id,
        stable_variant_id = opts.stable_variant_id,
        req_video_layout = opts.req_video_layout,
        name = opts.name,
    }
    obj.dumps = StreamInfo.dumps
    return obj
end

function StreamInfo:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("bandwidth", self.bandwidth))

    if self.average_bandwidth then
        tab_insert(parts, _fmt_attr("average_bandwidth", self.average_bandwidth))
    end
    if self.codecs then
        tab_insert(parts, _fmt_attr("codecs", self.codecs, true))
    end
    if self.resolution then
        tab_insert(parts, _fmt_attr("resolution", self.resolution))
    end
    if self.frame_rate then
        tab_insert(parts, _fmt_attr("frame_rate", self.frame_rate))
    end
    if self.audio then
        tab_insert(parts, _fmt_attr("audio", self.audio, true))
    end
    if self.video then
        tab_insert(parts, _fmt_attr("video", self.video, true))
    end
    if self.subtitles then
        tab_insert(parts, _fmt_attr("subtitles", self.subtitles, true))
    end
    if self.closed_captions then
        if self.closed_captions == "NONE" then
            tab_insert(parts, _fmt_attr("closed_captions", "NONE"))
        else
            tab_insert(parts, _fmt_attr("closed_captions", self.closed_captions, true))
        end
    end
    if self.program_id then
        tab_insert(parts, _fmt_attr("program_id", self.program_id))
    end
    if self.hdcp_level then
        tab_insert(parts, _fmt_attr("hdcp_level", self.hdcp_level))
    end
    if self.video_range then
        tab_insert(parts, _fmt_attr("video_range", self.video_range))
    end
    if self.pathway_id then
        tab_insert(parts, _fmt_attr("pathway_id", self.pathway_id, true))
    end
    if self.stable_variant_id then
        tab_insert(parts, _fmt_attr("stable_variant_id", self.stable_variant_id, true))
    end
    if self.req_video_layout then
        tab_insert(parts, _fmt_attr("req_video_layout", self.req_video_layout, true))
    end
    if self.name then
        tab_insert(parts, _fmt_attr("name", self.name, true))
    end

    return tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- Media
--------------------------------------------------------------------------------

local Media = {}

--- Create a new Media entry.
-- @param opts.media_type       string  media type (AUDIO, VIDEO, SUBTITLES, CLOSED-CAPTIONS)
-- @param opts.group_id         string  group identifier
-- @param opts.name             string  human-readable name
-- @param opts.language         string  RFC 5646 language tag (optional)
-- @param opts.assoc_language   string  associated language (optional)
-- @param opts.uri              string  media URI (optional for CLOSED-CAPTIONS)
-- @param opts.default          boolean is default rendition (optional)
-- @param opts.autoselect       boolean auto-select (optional)
-- @param opts.forced           boolean forced rendition (optional)
-- @param opts.instream_id      string  instream ID for CLOSED-CAPTIONS (optional)
-- @param opts.characteristics  string  characteristics string (optional)
-- @param opts.channels         string  channel spec (optional)
-- @param opts.stable_rendition_id string stable rendition id (optional)
function Media.new(opts)
    opts = opts or {}
    local obj = {
        media_type = opts.media_type or "",
        group_id = opts.group_id or "",
        name = opts.name or "",
        language = opts.language,
        assoc_language = opts.assoc_language,
        uri = opts.uri,
        default = opts.default or false,
        autoselect = opts.autoselect or false,
        forced = opts.forced or false,
        instream_id = opts.instream_id,
        characteristics = opts.characteristics,
        channels = opts.channels,
        stable_rendition_id = opts.stable_rendition_id,
    }
    obj.dumps = Media.dumps
    return obj
end

function Media:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("type", self.media_type))
    tab_insert(parts, _fmt_attr("group_id", self.group_id, true))
    tab_insert(parts, _fmt_attr("name", self.name, true))

    if self.language then
        tab_insert(parts, _fmt_attr("language", self.language, true))
    end
    if self.assoc_language then
        tab_insert(parts, _fmt_attr("assoc_language", self.assoc_language, true))
    end
    if self.uri then
        tab_insert(parts, _fmt_attr("uri", self.uri, true))
    end
    if self.default then
        tab_insert(parts, _fmt_attr("default", true))
    end
    if self.autoselect then
        tab_insert(parts, _fmt_attr("autoselect", true))
    end
    if self.forced then
        tab_insert(parts, _fmt_attr("forced", true))
    end
    if self.instream_id then
        tab_insert(parts, _fmt_attr("instream_id", self.instream_id, true))
    end
    if self.characteristics then
        tab_insert(parts, _fmt_attr("characteristics", self.characteristics, true))
    end
    if self.channels then
        tab_insert(parts, _fmt_attr("channels", self.channels, true))
    end
    if self.stable_rendition_id then
        tab_insert(parts, _fmt_attr("stable_rendition_id", self.stable_rendition_id, true))
    end

    return protocol.EXT_X_MEDIA .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- Segment
--------------------------------------------------------------------------------

-- Forward declarations (defined later in this file)
local Part
local DateRange

local Segment = {}

--- Create a new Segment.
function Segment.new(opts)
    opts = opts or {}

    -- Convert raw key data to Key object
    local key = opts.key
    if type(key) == "table" and not key.dumps then
        key = Key.new(key)
    end

    -- Convert raw map data to Map object
    local map = opts.map
    if type(map) == "table" and not map.dumps then
        map = Map.new(map)
    end

    -- Convert raw byterange data to ByteRange object
    local byterange = opts.byterange
    if type(byterange) == "table" and not byterange.dumps then
        byterange = ByteRange.new(byterange)
    end

    -- Convert raw parts to Part objects
    local parts = {}
    for _, p in ipairs(opts.parts or {}) do
        if type(p) == "table" and p.dumps then
            tab_insert(parts, p)
        else
            tab_insert(parts, Part.new(p))
        end
    end

    -- Convert raw dateranges to DateRange objects
    local dateranges = {}
    for _, dr in ipairs(opts.dateranges or {}) do
        if type(dr) == "table" and dr.dumps then
            tab_insert(dateranges, dr)
        else
            tab_insert(dateranges, DateRange.new(dr))
        end
    end

    local obj = {
        uri = opts.uri or "",
        duration = opts.duration or 0,
        title = opts.title,
        key = key,
        map = map,
        byterange = byterange,
        bitrate = opts.bitrate,
        discontinuity = opts.discontinuity or false,
        gap = opts.gap or false,
        program_date_time = opts.program_date_time,
        parts = parts,
        dateranges = dateranges,
        cue_out = opts.cue_out,
        cue_out_start = opts.cue_out_start,
        cue_out_explicitly_duration = opts.cue_out_explicitly_duration,
        cue_in = opts.cue_in or false,
        scte35 = opts.scte35,
        oatcls_scte35 = opts.oatcls_scte35,
        scte35_duration = opts.scte35_duration,
        scte35_elapsedtime = opts.scte35_elapsedtime,
        asset_metadata = opts.asset_metadata,
    }
    obj.dumps = Segment.dumps
    return obj
end

--- Construct a list of Segment objects from raw data array.
function Segment.new_list(data_array)
    local list = {}
    for _, seg_data in ipairs(data_array or {}) do
        tab_insert(list, Segment.new(seg_data))
    end
    list.dumps = Segment.list_dumps
    list.by_key = Segment.list_by_key
    return list
end

--- Serialize a list of segments.
-- @param last_segment table  the previous segment for key/map change detection
-- @param timespec     string time format specifier (reserved)
-- @param infspec      string EXTINF format specifier (reserved)
function Segment.list_dumps(list, timespec, infspec)
    local lines = {}
    local last_seg = nil

    for _, seg in ipairs(list) do
        local seg_lines = seg:dumps(last_seg, timespec, infspec)
        if seg_lines and seg_lines ~= "" then
            tab_insert(lines, seg_lines)
        end
        last_seg = seg
    end

    return tab_concat(lines, "\n")
end

--- Filter segments whose key matches the given key.
function Segment.list_by_key(list, key)
    local result = {}
    for _, seg in ipairs(list) do
        if seg.key == key then
            tab_insert(result, seg)
        end
    end
    return result
end

--- Serialize a single segment.
-- Outputs: DISCONTINUITY, PROGRAM-DATE-TIME, DATERANGE, CUE tags, PARTS,
--          EXTINF, BYTERANGE, BITRATE, GAP, then URI.
function Segment:dumps(last_segment, timespec, infspec)
    local lines = {}

    -- Key change detection
    if last_segment and self.key and last_segment.key then
        if self.key.uri ~= last_segment.key.uri
            or self.key.method ~= last_segment.key.method
            or self.key.iv ~= last_segment.key.iv then
            tab_insert(lines, self.key:dumps())
        end
    elseif self.key and not (last_segment and last_segment.key) then
        tab_insert(lines, self.key:dumps())
    end

    -- Map (init section) change detection
    if last_segment and self.map and last_segment.map then
        if self.map.uri ~= last_segment.map.uri then
            tab_insert(lines, self.map:dumps())
        end
    elseif self.map and not (last_segment and last_segment.map) then
        tab_insert(lines, self.map:dumps())
    end

    -- Discontinuity
    if self.discontinuity then
        tab_insert(lines, protocol.EXT_X_DISCONTINUITY)
    end

    -- Program date time
    if self.program_date_time then
        tab_insert(lines, protocol.EXT_X_PROGRAM_DATE_TIME .. ":" .. self.program_date_time)
    end

    -- DateRanges
    for _, dr in ipairs(self.dateranges) do
        tab_insert(lines, dr:dumps())
    end

    -- Cue / SCTE35 tags
    if self.cue_out then
        if self.oatcls_scte35 then
            tab_insert(lines, protocol.EXT_OATCLS_SCTE35 .. ":" .. self.oatcls_scte35)
        elseif self.asset_metadata then
            tab_insert(lines, protocol.EXT_X_ASSET .. ":" .. self.asset_metadata)
        elseif self.scte35 then
            local cue = protocol.EXT_X_CUE_OUT .. ":DURATION=" .. number_to_string(self.cue_out_explicitly_duration)
            tab_insert(lines, cue)
        else
            local cue = protocol.EXT_X_CUE_OUT .. ":DURATION=" .. number_to_string(self.cue_out_explicitly_duration or 0)
            tab_insert(lines, cue)
        end
    end

    if self.scte35_elapsedtime then
        tab_insert(lines, protocol.EXT_X_CUE_OUT_CONT
            .. ":ElapsedTime=" .. number_to_string(self.scte35_elapsedtime)
            .. ",Duration=" .. number_to_string(self.scte35_duration or 0)
            .. ",SCTE35=" .. self.scte35)
    end

    if self.cue_in then
        tab_insert(lines, protocol.EXT_X_CUE_IN)
    end

    if self.cue_out_start then
        tab_insert(lines, protocol.EXT_X_CUE_SPAN)
    end

    -- Parts
    for _, part in ipairs(self.parts) do
        tab_insert(lines, part:dumps())
    end

    -- EXTINF
    local infspec_val = infspec or "auto"
    local dur_str
    if infspec_val == "auto" and self.duration >= 9999999999999999 then
        dur_str = "INF"
    else
        dur_str = number_to_string(self.duration)
    end

    if self.title and self.title ~= "" then
        tab_insert(lines, protocol.EXTINF .. ":" .. dur_str .. "," .. self.title)
    else
        tab_insert(lines, protocol.EXTINF .. ":" .. dur_str .. ",")
    end

    -- ByteRange
    if self.byterange then
        tab_insert(lines, protocol.EXT_X_BYTERANGE .. ":" .. self.byterange:dumps())
    end

    -- Bitrate
    if self.bitrate then
        tab_insert(lines, protocol.EXT_X_BITRATE .. ":" .. tostring(self.bitrate))
    end

    -- Gap
    if self.gap then
        tab_insert(lines, protocol.EXT_X_GAP)
    end

    -- URI
    tab_insert(lines, self.uri)

    return tab_concat(lines, "\n")
end


--------------------------------------------------------------------------------
-- Part (Partial Segment)
--------------------------------------------------------------------------------

Part = {}

--- Create a new Part.
function Part.new(opts)
    opts = opts or {}
    local obj = {
        uri = opts.uri or "",
        duration = opts.duration or 0,
        independent = opts.independent or false,
        gap = opts.gap or false,
        byterange = opts.byterange,  -- ByteRange object
    }
    obj.dumps = Part.dumps
    return obj
end

function Part:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("duration", self.duration))
    tab_insert(parts, _fmt_attr("uri", self.uri, true))

    if self.independent then
        tab_insert(parts, _fmt_attr("independent", true))
    end
    if self.byterange then
        tab_insert(parts, _fmt_attr("byterange", self.byterange:dumps(), true))
    end
    if self.gap then
        tab_insert(parts, _fmt_attr("gap", true))
    end

    return protocol.EXT_X_PART .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- Playlist (variant stream)
--------------------------------------------------------------------------------

local Playlist = {}

--- Create a new Playlist (variant stream entry).
function Playlist.new(opts)
    opts = opts or {}
    local obj = {
        uri = opts.uri or "",
        stream_info = opts.stream_info,  -- StreamInfo object
        media = opts.media or {},        -- array of Media objects
    }
    obj.dumps = Playlist.dumps
    return obj
end

--- Build list of Playlists from raw data and media list.
function Playlist.new_list(playlist_data, media_list)
    local list = {}
    for _, pl_data in ipairs(playlist_data or {}) do
        local stream_info = StreamInfo.new(pl_data.stream_info or pl_data)
        local pl = Playlist.new({
            uri = pl_data.uri or "",
            stream_info = stream_info,
            media = media_list or {},
        })
        tab_insert(list, pl)
    end
    list.dumps = Playlist.list_dumps
    return list
end

function Playlist.list_dumps(list)
    local lines = {}
    for _, pl in ipairs(list) do
        tab_insert(lines, pl:dumps())
    end
    return tab_concat(lines, "\n")
end

--- Find matching media entries for this playlist.
local function find_media_for_playlist(playlist, all_media)
    local audio_group = playlist.stream_info.audio
    local video_group = playlist.stream_info.video
    local subtitles_group = playlist.stream_info.subtitles
    local cc_group = playlist.stream_info.closed_captions

    -- Return media groups that match
    return {
        audio = audio_group,
        video = video_group,
        subtitles = subtitles_group,
        closed_captions = cc_group,
    }
end

function Playlist:dumps()
    local extra_attrs = {}

    if self.stream_info.audio then
        tab_insert(extra_attrs, _fmt_attr("audio", self.stream_info.audio, true))
    end
    if self.stream_info.video then
        tab_insert(extra_attrs, _fmt_attr("video", self.stream_info.video, true))
    end
    if self.stream_info.subtitles then
        tab_insert(extra_attrs, _fmt_attr("subtitles", self.stream_info.subtitles, true))
    end
    if self.stream_info.closed_captions then
        if self.stream_info.closed_captions == "NONE" then
            tab_insert(extra_attrs, _fmt_attr("closed_captions", "NONE"))
        else
            tab_insert(extra_attrs, _fmt_attr("closed_captions", self.stream_info.closed_captions, true))
        end
    end

    local stream_str = self.stream_info:dumps()
    if #extra_attrs > 0 then
        stream_str = stream_str .. "," .. tab_concat(extra_attrs, ",")
    end

    return protocol.EXT_X_STREAM_INF .. ":" .. stream_str .. "\n" .. self.uri
end


--------------------------------------------------------------------------------
-- IFramePlaylist
--------------------------------------------------------------------------------

local IFramePlaylist = {}

--- Create a new IFramePlaylist.
function IFramePlaylist.new(opts)
    opts = opts or {}
    local obj = {
        uri = opts.uri or "",
        stream_info = opts.stream_info,  -- StreamInfo object
    }
    obj.dumps = IFramePlaylist.dumps
    return obj
end

function IFramePlaylist:dumps()
    local stream_str = self.stream_info:dumps()
    local uri_attr = _fmt_attr("uri", self.uri, true)
    return protocol.EXT_X_I_FRAME_STREAM_INF .. ":" .. stream_str .. "," .. uri_attr
end


--------------------------------------------------------------------------------
-- ImagePlaylist
--------------------------------------------------------------------------------

local ImagePlaylist = {}

--- Create a new ImagePlaylist.
function ImagePlaylist.new(opts)
    opts = opts or {}
    local obj = {
        uri = opts.uri or "",
        stream_info = opts.stream_info,  -- StreamInfo object
    }
    obj.dumps = ImagePlaylist.dumps
    return obj
end

function ImagePlaylist:dumps()
    local stream_str = self.stream_info:dumps()
    local uri_attr = _fmt_attr("uri", self.uri, true)
    return protocol.EXT_X_IMAGE_STREAM_INF .. ":" .. stream_str .. "," .. uri_attr
end


--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

local Start = {}

--- Create a new Start object.
function Start.new(opts)
    opts = opts or {}
    local obj = {
        time_offset = opts.time_offset or 0,
        precise = opts.precise or false,
    }
    obj.dumps = Start.dumps
    return obj
end

function Start:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("time_offset", self.time_offset))
    if self.precise then
        tab_insert(parts, _fmt_attr("precise", true))
    end
    return protocol.EXT_X_START .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- ServerControl
--------------------------------------------------------------------------------

local ServerControl = {}

--- Create a new ServerControl object.
function ServerControl.new(opts)
    opts = opts or {}
    local obj = {
        can_skip_until = opts.can_skip_until,
        can_block_reload = opts.can_block_reload,
        hold_back = opts.hold_back,
        part_hold_back = opts.part_hold_back,
        can_skip_dateranges = opts.can_skip_dateranges,
    }
    obj.dumps = ServerControl.dumps
    return obj
end

function ServerControl:dumps()
    local parts = {}
    if self.can_skip_until then
        tab_insert(parts, _fmt_attr("can_skip_until", self.can_skip_until))
    end
    if self.can_block_reload then
        tab_insert(parts, _fmt_attr("can_block_reload", true))
    end
    if self.hold_back then
        tab_insert(parts, _fmt_attr("hold_back", self.hold_back))
    end
    if self.part_hold_back then
        tab_insert(parts, _fmt_attr("part_hold_back", self.part_hold_back))
    end
    if self.can_skip_dateranges then
        tab_insert(parts, _fmt_attr("can_skip_dateranges", true))
    end
    return protocol.EXT_X_SERVER_CONTROL .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- PartInformation
--------------------------------------------------------------------------------

local PartInformation = {}

--- Create a new PartInformation object.
function PartInformation.new(opts)
    opts = opts or {}
    local obj = {
        part_target = opts.part_target,
    }
    obj.dumps = PartInformation.dumps
    return obj
end

function PartInformation:dumps()
    return protocol.EXT_X_PART_INF .. ":PART-TARGET=" .. number_to_string(self.part_target)
end


--------------------------------------------------------------------------------
-- Skip
--------------------------------------------------------------------------------

local Skip = {}

--- Create a new Skip object.
function Skip.new(opts)
    opts = opts or {}
    local obj = {
        skipped_segments = opts.skipped_segments or 0,
        recently_removed_dateranges = opts.recently_removed_dateranges,
    }
    obj.dumps = Skip.dumps
    return obj
end

function Skip:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("skipped_segments", self.skipped_segments))
    if self.recently_removed_dateranges then
        tab_insert(parts, _fmt_attr("recently_removed_dateranges", self.recently_removed_dateranges, true))
    end
    return protocol.EXT_X_SKIP .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- PreloadHint
--------------------------------------------------------------------------------

local PreloadHint = {}

--- Create a new PreloadHint object.
function PreloadHint.new(opts)
    opts = opts or {}
    local obj = {
        hint_type = opts.hint_type or "",   -- "hint_type" to avoid Lua "type" keyword
        uri = opts.uri or "",
        byterange_start = opts.byterange_start,
        byterange_length = opts.byterange_length,
    }
    obj.dumps = PreloadHint.dumps
    return obj
end

function PreloadHint:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("type", self.hint_type))
    tab_insert(parts, _fmt_attr("uri", self.uri, true))
    if self.byterange_start then
        tab_insert(parts, _fmt_attr("byterange_start", self.byterange_start))
    end
    if self.byterange_length then
        tab_insert(parts, _fmt_attr("byterange_length", self.byterange_length))
    end
    return protocol.EXT_X_PRELOAD_HINT .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- SessionData
--------------------------------------------------------------------------------

local SessionData = {}

--- Create a new SessionData object.
function SessionData.new(opts)
    opts = opts or {}
    local obj = {
        data_id = opts.data_id or "",
        value = opts.value,
        uri = opts.uri,
        language = opts.language,
    }
    obj.dumps = SessionData.dumps
    return obj
end

function SessionData:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("data_id", self.data_id, true))
    if self.value then
        tab_insert(parts, _fmt_attr("value", self.value, true))
    end
    if self.uri then
        tab_insert(parts, _fmt_attr("uri", self.uri, true))
    end
    if self.language then
        tab_insert(parts, _fmt_attr("language", self.language, true))
    end
    return protocol.EXT_X_SESSION_DATA .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- SessionKey
--------------------------------------------------------------------------------

local SessionKey = {}

--- Create a new SessionKey.
function SessionKey.new(opts)
    opts = opts or {}
    local obj = {
        method = opts.method or "NONE",
        uri = opts.uri,
        iv = opts.iv,
        keyformat = opts.keyformat,
        keyformatversions = opts.keyformatversions,
    }
    obj.dumps = SessionKey.dumps
    obj.tag = protocol.EXT_X_SESSION_KEY
    return obj
end

function SessionKey:dumps()
    local attrs = {}
    tab_insert(attrs, _fmt_attr("method", self.method))
    if self.uri then
        tab_insert(attrs, _fmt_attr("uri", self.uri, true))
    end
    if self.iv then
        tab_insert(attrs, _fmt_attr("iv", self.iv))
    end
    if self.keyformat then
        tab_insert(attrs, _fmt_attr("keyformat", self.keyformat, true))
    end
    if self.keyformatversions then
        tab_insert(attrs, _fmt_attr("keyformatversions", self.keyformatversions, true))
    end
    return self.tag .. ":" .. tab_concat(attrs, ",")
end


--------------------------------------------------------------------------------
-- DateRange
--------------------------------------------------------------------------------

DateRange = {}

--- Create a new DateRange object.
function DateRange.new(opts)
    opts = opts or {}
    local obj = {
        id = opts.id or "",
        class = opts.class or opts.class_,
        start_date = opts.start_date or "",
        end_date = opts.end_date,
        duration = opts.duration,
        planned_duration = opts.planned_duration,
        scte35_cmd = opts.scte35_cmd,
        scte35_out = opts.scte35_out,
        scte35_in = opts.scte35_in,
        end_on_next = opts.end_on_next or false,
        x_attributes = opts.x_attributes or {},  -- {name = value, ...}
    }
    obj.dumps = DateRange.dumps
    return obj
end

function DateRange:dumps()
    local parts = {}

    tab_insert(parts, _fmt_attr("id", self.id, true))
    if self.class then
        tab_insert(parts, _fmt_attr("class", self.class, true))
    end
    tab_insert(parts, _fmt_attr("start_date", self.start_date, true))

    if self.end_date then
        tab_insert(parts, _fmt_attr("end_date", self.end_date, true))
    end
    if self.duration then
        tab_insert(parts, _fmt_attr("duration", self.duration))
    end
    if self.planned_duration then
        tab_insert(parts, _fmt_attr("planned_duration", self.planned_duration))
    end
    if self.scte35_cmd then
        tab_insert(parts, _fmt_attr("scte35_cmd", self.scte35_cmd))
    end
    if self.scte35_out then
        tab_insert(parts, _fmt_attr("scte35_out", self.scte35_out))
    end
    if self.scte35_in then
        tab_insert(parts, _fmt_attr("scte35_in", self.scte35_in))
    end
    if self.end_on_next then
        tab_insert(parts, _fmt_attr("end_on_next", true))
    end

    -- Custom X- attributes (sorted alphabetically)
    local x_keys = {}
    for k in pairs(self.x_attributes) do
        tab_insert(x_keys, k)
    end
    tab_sort(x_keys)
    for _, k in ipairs(x_keys) do
        local hls_k = "X-" .. denormalize_attribute(k)
        local v = self.x_attributes[k]
        if type(v) == "string" and needs_quoting(v) then
            tab_insert(parts, hls_k .. "=\"" .. v .. "\"")
        else
            tab_insert(parts, hls_k .. "=" .. tostring(v))
        end
    end

    return protocol.EXT_X_DATERANGE .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- ContentSteering
--------------------------------------------------------------------------------

local ContentSteering = {}

--- Create a new ContentSteering object.
function ContentSteering.new(opts)
    opts = opts or {}
    local obj = {
        server_uri = opts.server_uri or "",
        pathway_id = opts.pathway_id,
    }
    obj.dumps = ContentSteering.dumps
    return obj
end

function ContentSteering:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("server_uri", self.server_uri, true))
    if self.pathway_id then
        tab_insert(parts, _fmt_attr("pathway_id", self.pathway_id, true))
    end
    return protocol.EXT_X_CONTENT_STEERING .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- RenditionReport
--------------------------------------------------------------------------------

local RenditionReport = {}

--- Create a new RenditionReport object.
function RenditionReport.new(opts)
    opts = opts or {}
    local obj = {
        uri = opts.uri or "",
        last_msn = opts.last_msn,
        last_part = opts.last_part,
    }
    obj.dumps = RenditionReport.dumps
    return obj
end

function RenditionReport:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("uri", self.uri, true))
    if self.last_msn then
        tab_insert(parts, _fmt_attr("last_msn", self.last_msn))
    end
    if self.last_part then
        tab_insert(parts, _fmt_attr("last_part", self.last_part))
    end
    return protocol.EXT_X_RENDITION_REPORT .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- Tiles
--------------------------------------------------------------------------------

local Tiles = {}

--- Create a new Tiles object.
function Tiles.new(opts)
    opts = opts or {}
    local obj = {
        resolution = opts.resolution or "",
        layout = opts.layout or "",
        duration = opts.duration or 0,
        uri = opts.uri,
    }
    obj.dumps = Tiles.dumps
    return obj
end

function Tiles:dumps()
    local parts = {}
    tab_insert(parts, _fmt_attr("resolution", self.resolution))
    tab_insert(parts, _fmt_attr("layout", self.layout))
    tab_insert(parts, _fmt_attr("duration", self.duration))
    if self.uri then
        tab_insert(parts, _fmt_attr("uri", self.uri, true))
    end
    return protocol.EXT_X_TILES .. ":" .. tab_concat(parts, ",")
end


--------------------------------------------------------------------------------
-- M3U8 — Top-level playlist
--------------------------------------------------------------------------------

local M3U8 = {}

--- Create a new M3U8 object from parsed data table.
-- @param data  table  the data dict returned by parser.parse()
function M3U8.new(data)
    data = data or {}

    local segments
    if data.segments and data.segments.dumps then
        -- Already wrapped in SegmentList
        segments = data.segments
    else
        segments = Segment.new_list(data.segments or {})
    end

    -- Build playlists with stream_info as StreamInfo objects
    local playlists = {}
    for _, pl_data in ipairs(data.playlists or {}) do
        local stream_info = StreamInfo.new(pl_data.stream_info or pl_data)
        local pl = Playlist.new({
            uri = pl_data.uri or "",
            stream_info = stream_info,
            media = data.media or {},
        })
        tab_insert(playlists, pl)
    end

    -- Build iframe playlists
    local iframe_playlists = {}
    for _, pl_data in ipairs(data.iframe_playlists or {}) do
        local stream_info = StreamInfo.new(pl_data.stream_info or pl_data)
        local pl = IFramePlaylist.new({
            uri = pl_data.uri or "",
            stream_info = stream_info,
        })
        tab_insert(iframe_playlists, pl)
    end

    -- Build image playlists
    local image_playlists = {}
    for _, pl_data in ipairs(data.image_playlists or {}) do
        local stream_info = StreamInfo.new(pl_data.stream_info or pl_data)
        local pl = ImagePlaylist.new({
            uri = pl_data.uri or "",
            stream_info = stream_info,
        })
        tab_insert(image_playlists, pl)
    end

    -- Build media objects
    local media_list = {}
    for _, m_data in ipairs(data.media or {}) do
        tab_insert(media_list, Media.new(m_data))
    end

    -- Build keys
    local keys = {}
    for _, k_data in ipairs(data.keys or {}) do
        tab_insert(keys, Key.new(k_data))
    end

    -- Build session keys
    local session_keys = {}
    for _, k_data in ipairs(data.session_keys or {}) do
        tab_insert(session_keys, SessionKey.new(k_data))
    end

    -- Build session data
    local session_data = {}
    for _, sd_data in ipairs(data.session_data or {}) do
        tab_insert(session_data, SessionData.new(sd_data))
    end

    -- Build rendition reports
    local rendition_reports = {}
    for _, rr_data in ipairs(data.rendition_reports or {}) do
        tab_insert(rendition_reports, RenditionReport.new(rr_data))
    end

    local obj = {
        is_variant = data.is_variant or false,
        is_endlist = data.is_endlist or false,
        is_i_frames_only = data.is_i_frames_only or false,
        is_independent_segments = data.is_independent_segments or false,
        is_images_only = data.is_images_only or false,
        target_duration = data.target_duration or data.targetduration or 0,
        media_sequence = data.media_sequence or 0,
        discontinuity_sequence = data.discontinuity_sequence,
        playlist_type = data.playlist_type,
        version = data.version,
        allow_cache = data.allow_cache,
        program_date_time = data.program_date_time,
        segments = segments,
        playlists = playlists,
        iframe_playlists = iframe_playlists,
        image_playlists = image_playlists,
        media = media_list,
        keys = keys,
        session_keys = session_keys,
        session_data = session_data,
        rendition_reports = rendition_reports,
        start = data.start and Start.new(data.start) or nil,
        server_control = data.server_control and ServerControl.new(data.server_control) or nil,
        part_inf = data.part_inf and PartInformation.new(data.part_inf) or nil,
        skip = data.skip and Skip.new(data.skip) or nil,
        preload_hint = data.preload_hint and PreloadHint.new(data.preload_hint) or nil,
        content_steering = data.content_steering and ContentSteering.new(data.content_steering) or nil,
        tiles = data.tiles and Tiles.new(data.tiles) or nil,
        segment_map = nil,  -- top-level map, built below
        dateranges = {},
    }

    -- Top-level segment map
    if data.segment_map then
        obj.segment_map = Map.new(data.segment_map)
    end

    -- DateRanges at top level
    for _, dr_data in ipairs(data.dateranges or {}) do
        tab_insert(obj.dateranges, DateRange.new(dr_data))
    end

    obj.dumps = M3U8.dumps
    return obj
end

--- Serialize the full playlist back to an m3u8 string.
-- @param timespec  string  time format for dates (reserved, default "milliseconds")
-- @param infspec   string  EXTINF format (reserved, default "auto")
function M3U8:dumps(timespec, infspec)
    local lines = {}

    -- Header
    tab_insert(lines, protocol.EXTM3U)

    -- Images only
    if self.is_images_only then
        tab_insert(lines, protocol.EXT_X_IMAGES_ONLY)
    end

    -- Tiles
    if self.tiles then
        tab_insert(lines, self.tiles:dumps())
    end

    -- Version
    if self.version then
        tab_insert(lines, protocol.EXT_X_VERSION .. ":" .. tostring(self.version))
    end

    -- Playlist type
    if self.playlist_type then
        tab_insert(lines, protocol.EXT_X_PLAYLIST_TYPE .. ":" .. self.playlist_type)
    end

    -- Target duration (media playlists)
    if self.target_duration and self.target_duration > 0 and not self.is_variant then
        tab_insert(lines, protocol.EXT_X_TARGETDURATION .. ":" .. tostring(self.target_duration))
    end

    -- Media sequence
    if self.media_sequence and self.media_sequence > 0 then
        tab_insert(lines, protocol.EXT_X_MEDIA_SEQUENCE .. ":" .. tostring(self.media_sequence))
    end

    -- Discontinuity sequence
    if self.discontinuity_sequence then
        tab_insert(lines, protocol.EXT_X_DISCONTINUITY_SEQUENCE .. ":" .. tostring(self.discontinuity_sequence))
    end

    -- Independent segments
    if self.is_independent_segments then
        tab_insert(lines, protocol.EXT_X_INDEPENDENT_SEGMENTS)
    end

    -- Start
    if self.start then
        tab_insert(lines, self.start:dumps())
    end

    -- Server control (media playlists)
    if self.server_control and not self.is_variant then
        tab_insert(lines, self.server_control:dumps())
    end

    -- Part inf
    if self.part_inf then
        tab_insert(lines, self.part_inf:dumps())
    end

    -- Skip
    if self.skip then
        tab_insert(lines, self.skip:dumps())
    end

    -- Allow cache
    if self.allow_cache then
        tab_insert(lines, protocol.EXT_X_ALLOW_CACHE .. ":" .. self.allow_cache)
    end

    -- Session data
    for _, sd in ipairs(self.session_data) do
        tab_insert(lines, sd:dumps())
    end

    -- Session keys
    for _, sk in ipairs(self.session_keys) do
        tab_insert(lines, sk:dumps())
    end

    -- Content steering
    if self.content_steering then
        tab_insert(lines, self.content_steering:dumps())
    end

    -- Preload hint
    if self.preload_hint then
        tab_insert(lines, self.preload_hint:dumps())
    end

    -- Media entries (master playlist)
    for _, m in ipairs(self.media) do
        tab_insert(lines, m:dumps())
    end

    -- Playlists (master playlist variants)
    for _, pl in ipairs(self.playlists) do
        tab_insert(lines, pl:dumps())
    end

    -- IFrame playlists
    for _, pl in ipairs(self.iframe_playlists) do
        tab_insert(lines, pl:dumps())
    end

    -- Image playlists
    for _, pl in ipairs(self.image_playlists) do
        tab_insert(lines, pl:dumps())
    end

    -- Top-level Map
    if self.segment_map then
        tab_insert(lines, self.segment_map:dumps())
    end

    -- Segments
    if self.segments and #self.segments > 0 then
        if self.segments.dumps then
            tab_insert(lines, self.segments:dumps(nil, timespec, infspec))
        else
            local seg_lines = {}
            local last_seg = nil
            for _, seg in ipairs(self.segments) do
                local s = seg:dumps(last_seg, timespec, infspec)
                if s and s ~= "" then
                    tab_insert(seg_lines, s)
                end
                last_seg = seg
            end
            tab_insert(lines, tab_concat(seg_lines, "\n"))
        end
    end

    -- Rendition reports
    for _, rr in ipairs(self.rendition_reports) do
        tab_insert(lines, rr:dumps())
    end

    -- Endlist
    if self.is_endlist then
        tab_insert(lines, protocol.EXT_X_ENDLIST)
    end

    return tab_concat(lines, "\n") .. "\n"
end


return {
    M3U8 = M3U8,
    Segment = Segment,
    Part = Part,
    Key = Key,
    SessionKey = SessionKey,
    Map = Map,
    StreamInfo = StreamInfo,
    Media = Media,
    Playlist = Playlist,
    IFramePlaylist = IFramePlaylist,
    ImagePlaylist = ImagePlaylist,
    ByteRange = ByteRange,
    Start = Start,
    ServerControl = ServerControl,
    PartInformation = PartInformation,
    Skip = Skip,
    PreloadHint = PreloadHint,
    SessionData = SessionData,
    DateRange = DateRange,
    ContentSteering = ContentSteering,
    RenditionReport = RenditionReport,
    Tiles = Tiles,
}
