--- M3U8 playlist parser for OpenResty.
--
-- Parses HLS m3u8 playlists (both media and master) and provides
-- serialization back to m3u8 text.
--
-- @module resty.m3u8
--
-- Usage:
--   local m3u8 = require("resty.m3u8")
--   local playlist, err = m3u8.loads(content)
--   if not playlist then
--       ngx.log(ngx.ERR, "m3u8 parse failed: ", err)
--       return
--   end
--
--   -- Access segments
--   for _, seg in ipairs(playlist.segments) do
--       ngx.say(seg.uri, " duration=", seg.duration)
--   end
--
--   -- Serialize back
--   local output = playlist:dumps()

local parser = require("resty.m3u8.parser")
local model = require("resty.m3u8.model")
local protocol = require("resty.m3u8.protocol")

local _M = {
    version = "0.2.0",
}


--- Parse m3u8 content string and return a M3U8 playlist object.
--
-- @param  content  string  raw m3u8 playlist text
-- @param  strict   boolean (optional, default false) error on unknown HLS tags
-- @return M3U8 object on success
-- @return nil, error_message on failure
function _M.loads(content, strict)
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end

    local data, err = parser.parse(content, strict)
    if not data then
        return nil, err
    end

    return model.M3U8.new(data)
end


--- Parse m3u8 content into a raw data table (lower-level access).
--
-- This bypasses model object construction and returns the raw parsed
-- data structure directly.
--
-- @param  content  string  raw m3u8 playlist text
-- @param  strict   boolean (optional, default false) error on unknown HLS tags
-- @return table    parsed data table on success
-- @return nil, error_message on failure
function _M.parse(content, strict)
    return parser.parse(content, strict)
end


-- Expose the protocol constants table
_M.protocol = protocol

-- Expose model constructors for building playlists programmatically
_M.M3U8 = model.M3U8
_M.Segment = model.Segment
_M.Part = model.Part
_M.Key = model.Key
_M.SessionKey = model.SessionKey
_M.Map = model.Map
_M.StreamInfo = model.StreamInfo
_M.Media = model.Media
_M.Playlist = model.Playlist
_M.IFramePlaylist = model.IFramePlaylist
_M.ImagePlaylist = model.ImagePlaylist
_M.ByteRange = model.ByteRange
_M.Start = model.Start
_M.ServerControl = model.ServerControl
_M.PartInformation = model.PartInformation
_M.Skip = model.Skip
_M.PreloadHint = model.PreloadHint
_M.SessionData = model.SessionData
_M.DateRange = model.DateRange
_M.ContentSteering = model.ContentSteering
_M.RenditionReport = model.RenditionReport
_M.Tiles = model.Tiles


return _M
