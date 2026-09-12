# lua-resty-m3u8

HLS M3U8 playlist parser and serializer for OpenResty, written in LuaJIT-friendly plain Lua.

Parses both media and master playlists, supporting the full range of HLS tags including Low-Latency HLS (LL-HLS) parts, preload hints, rendition reports, SCTE35/CUE ad insertion markers, and content steering.

Based on [m3u8](https://github.com/globocom/m3u8), rewritten and adapted for OpenResty / LuaJIT with JIT-friendly plain Lua (no LPeg dependency).

## Installation

```bash
luarocks install lua-resty-m3u8
```

Or via a local rockspec:

```bash
luarocks make lua-resty-m3u8-0.2-0.rockspec
```

## Usage

```lua
local m3u8 = require("resty.m3u8")

-- Parse a media playlist
local playlist, err = m3u8.loads(content)
if not playlist then
    ngx.log(ngx.ERR, "m3u8 parse failed: ", err)
    return
end

-- Iterate segments
for _, seg in ipairs(playlist.segments) do
    ngx.say(seg.uri, " duration=", seg.duration)
    if seg.key then
        ngx.say("  key=", seg.key.uri, " method=", seg.key.method)
    end
end

-- Serialize back to m3u8 text
local output = playlist:dumps()
```

### Master (variant) playlists

```lua
local playlist = m3u8.loads(master_content)

for _, pl in ipairs(playlist.playlists) do
    local info = pl.stream_info
    ngx.say(pl.uri, " bandwidth=", info.bandwidth, " resolution=", info.resolution)
end

for _, m in ipairs(playlist.media) do
    ngx.say(m.media_type, " ", m.name, " language=", m.language)
end

-- Serialize back
local output = playlist:dumps()
```

### Programmatic construction

```lua
local m3u8 = require("resty.m3u8")

local seg = m3u8.Segment.new({
    uri = "segment-1.ts",
    duration = 10.0,
    title = "segment 1",
    key = m3u8.Key.new({
        method = "AES-128",
        uri = "https://example.com/key.bin",
        iv = "0xABCD1234",
    }),
})

local playlist = m3u8.M3U8.new({
    version = 3,
    target_duration = 10,
    media_sequence = 1,
    segments = { seg },
    is_endlist = true,
})

ngx.print(playlist:dumps())
```

### Strict mode

```lua
-- Pass true as second argument to reject unknown tags
local playlist, err = m3u8.loads(content, true)
```

### Raw parse (bypasses model objects)

```lua
local data, err = m3u8.parse(content)
-- Returns a plain nested table structure
```

## Supported HLS tags

**Media playlist:** `#EXTINF`, `#EXT-X-TARGETDURATION`, `#EXT-X-MEDIA-SEQUENCE`, `#EXT-X-DISCONTINUITY-SEQUENCE`, `#EXT-X-ENDLIST`, `#EXT-X-PLAYLIST-TYPE`, `#EXT-X-I-FRAMES-ONLY`, `#EXT-X-IMAGES-ONLY`, `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-VERSION`, `#EXT-X-ALLOW-CACHE`, `#EXT-X-KEY`, `#EXT-X-MAP`, `#EXT-X-BYTERANGE`, `#EXT-X-GAP`, `#EXT-X-BITRATE`, `#EXT-X-PROGRAM-DATE-TIME`, `#EXT-X-DISCONTINUITY`, `#EXT-X-DATERANGE`

**Master playlist:** `#EXT-X-STREAM-INF`, `#EXT-X-I-FRAME-STREAM-INF`, `#EXT-X-IMAGE-STREAM-INF`, `#EXT-X-MEDIA`, `#EXT-X-SESSION-DATA`, `#EXT-X-SESSION-KEY`, `#EXT-X-CONTENT-STEERING`

**LL-HLS:** `#EXT-X-SERVER-CONTROL`, `#EXT-X-PART-INF`, `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT`, `#EXT-X-SKIP`, `#EXT-X-DEFINE`

**SCTE35 / Ad insertion:** `#EXT-X-CUE-OUT`, `#EXT-X-CUE-OUT-CONT`, `#EXT-X-CUE-IN`, `#EXT-X-CUE-SPAN`, `#EXT-OATCLS-SCTE35`, `#EXT-X-ASSET`

**Image tiles:** `#EXT-X-TILES`

## Model classes

All model classes support `:dumps()` for serialization back to HLS tag format:

- `M3U8` — top-level playlist object
- `Segment` — media segment
- `Part` — LL-HLS partial segment
- `Key` / `SessionKey` — encryption keys
- `Map` — initialization section (`#EXT-X-MAP`)
- `Playlist` / `IFramePlaylist` / `ImagePlaylist` — variant stream entries
- `StreamInfo` — stream variant attributes
- `Media` — media rendition entry
- `ByteRange` — byte range specifier
- `Start` / `ServerControl` / `PartInformation` / `Skip` / `PreloadHint`
- `DateRange` — date range metadata (including X- custom attributes)
- `ContentSteering` / `RenditionReport` / `SessionData` / `Tiles`

## Running tests

```bash
prove -I /path/to/test-nginx/lib t/m3u8.t
```

The suite runs the parser inside OpenResty with Test::Nginx. Set
`TEST_NGINX_BINARY` when the OpenResty nginx executable is not on `PATH`.

## Dependencies

- OpenResty (ngx_lua)
- `table.clone` (bundled with lua-resty-core)
