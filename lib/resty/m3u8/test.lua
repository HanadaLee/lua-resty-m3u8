--- Test script for the m3u8 parser module.
--
-- Run with: resty test.lua

local passed = 0
local failed = 0

local function assert_equal(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg)
        print("  expected: " .. tostring(expected))
        print("  actual:   " .. tostring(actual))
    end
end

local function assert_not_nil(val, msg)
    if val ~= nil then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg .. " (got nil)")
    end
end

local function assert_true(val, msg)
    if val == true then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg .. " (expected true)")
    end
end

local function assert_false(val, msg)
    if val == false then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg .. " (expected false)")
    end
end

local function section(name)
    print("\n=== " .. name .. " ===")
end

local function assert_nil(val, msg)
    if val == nil then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg .. " (expected nil, got " .. tostring(val) .. ")")
    end
end


local protocol = require("resty.m3u8.protocol")
local parser = require("resty.m3u8.parser")
local m3u8 = require("resty.m3u8")


--------------------------------------------------------------------------------
-- 1. parse_attributes
--------------------------------------------------------------------------------

section("parse_attributes")

local attrs = protocol.parse_attributes("METHOD=AES-128,URI=\"https://example.com/key.bin\",IV=0xABCD1234")
assert_equal(attrs.method, "AES-128", "method parsed")
assert_equal(attrs.uri, "https://example.com/key.bin", "uri parsed (quotes removed)")
assert_equal(attrs.iv, "0xABCD1234", "iv hex preserved as string")

local attrs2 = protocol.parse_attributes('NAME="Foo, Bar",DEFAULT=YES')
assert_equal(attrs2.name, "Foo, Bar", "quoted comma preserved")
assert_equal(attrs2.default, "YES", "default value parsed")

local attrs3 = protocol.parse_attributes("DEFAULT=YES,AUTOSELECT=NO")
assert_equal(attrs3.default, "YES", "YES parsed as string")
assert_equal(attrs3.autoselect, "NO", "NO parsed as string")

local attrs4 = protocol.parse_attributes("BANDWIDTH=5000000,AVERAGE-BANDWIDTH=3000000")
assert_equal(attrs4.bandwidth, 5000000, "integer parsed as number")
assert_equal(attrs4.average_bandwidth, 3000000, "hyphen-to-underscore + number")

local attrs5 = protocol.parse_attributes("TITLE=")
assert_equal(attrs5.title, "", "empty value")

-- Single quoted values
local attrs6 = protocol.parse_attributes("TITLE='Hello'")
assert_equal(attrs6.title, "Hello", "single-quoted value")

local attrs7 = protocol.parse_attributes('VALUE="hello""world"')
assert_equal(attrs7.value, 'hello"world', "escaped double-quote inside value")


--------------------------------------------------------------------------------
-- 2. Media playlist -- basic features
--------------------------------------------------------------------------------

section("Media playlist")

local media_playlist = [[
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:1
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-ALLOW-CACHE:YES
#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin",IV=0xABCD1234
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:00Z
#EXTINF:10.0,segment 1
#EXT-X-BYTERANGE:1234@5678
segment-1.ts
#EXTINF:5.5,segment 2
segment-2.ts
#EXT-X-DISCONTINUITY
#EXTINF:8.0,segment 3
segment-3.ts
#EXT-X-ENDLIST
]]

local data, err = parser.parse(media_playlist)
assert_not_nil(data, "media playlist parsed")
assert_equal(err, nil, "no error: " .. (err or "ok"))
assert_equal(data.version, 3, "version")
assert_equal(data.target_duration, 10, "target_duration")
assert_equal(data.media_sequence, 1, "media_sequence")
assert_equal(data.playlist_type, "VOD", "playlist_type")
assert_equal(data.is_endlist, true, "is_endlist")
assert_equal(#data.segments, 3, "segment count")

local seg1 = data.segments[1]
assert_equal(seg1.uri, "segment-1.ts", "seg1 uri")
assert_equal(seg1.duration, 10.0, "seg1 duration")
assert_equal(seg1.title, "segment 1", "seg1 title")
assert_not_nil(seg1.key, "seg1 has key")
assert_equal(seg1.key.method, "AES-128", "seg1 key method")
assert_not_nil(seg1.map, "seg1 has map")
assert_equal(seg1.map.uri, "init.mp4", "seg1 map uri")
assert_not_nil(seg1.byterange, "seg1 has byterange")
assert_equal(seg1.byterange.length, 1234, "seg1 byterange length")
assert_equal(seg1.byterange.offset, 5678, "seg1 byterange offset")

local seg2 = data.segments[2]
assert_equal(seg2.uri, "segment-2.ts", "seg2 uri")
assert_equal(seg2.duration, 5.5, "seg2 duration")
assert_equal(seg2.title, "segment 2", "seg2 title")

local seg3 = data.segments[3]
assert_equal(seg3.uri, "segment-3.ts", "seg3 uri")
assert_equal(seg3.discontinuity, true, "seg3 discontinuity")
assert_equal(#data.keys, 1, "keys count")


--------------------------------------------------------------------------------
-- 3. Float duration, comma in title, line breaks
--------------------------------------------------------------------------------

section("Edge cases: float duration, comma in title, line breaks")

local float_dur_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.123,\nsegment.ts\n#EXT-X-ENDLIST\n"
local fd, _ = parser.parse(float_dur_pl)
assert_equal(fd.segments[1].duration, 5.123, "float duration (5.123)")

local comma_title_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,Title with a comma, end\nsegment.ts\n#EXT-X-ENDLIST\n"
local ct, _ = parser.parse(comma_title_pl)
assert_equal(ct.segments[1].title, "Title with a comma, end", "comma in title")

local crlf_pl = "#EXTM3U\r\n#EXT-X-TARGETDURATION:5\r\n#EXTINF:5.0,\r\nsegment.ts\r\n#EXT-X-ENDLIST\r\n"
local lf, _ = parser.parse(crlf_pl)
assert_equal(lf.target_duration, 5, "CRLF line breaks")
assert_equal(#lf.segments, 1, "CRLF segment count")

local commaless_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0\nsegment.ts\n#EXT-X-ENDLIST\n"
local cl, _ = parser.parse(commaless_pl)
assert_equal(cl.segments[1].duration, 5.0, "commaless EXTINF duration")

local no_title_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,\nsegment.ts\n#EXT-X-ENDLIST\n"
local nt, _ = parser.parse(no_title_pl)
assert_equal(nt.segments[1].title, "", "empty title (comma present, no text)")


--------------------------------------------------------------------------------
-- 4. Live sliding window playlist
--------------------------------------------------------------------------------

section("Live sliding window")

local live_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:2680
#EXTINF:8.0,
segment-2680.ts
#EXTINF:8.0,
segment-2681.ts
#EXTINF:8.0,
segment-2682.ts
]]

local live, _ = parser.parse(live_pl)
assert_equal(live.target_duration, 8, "live target_duration")
assert_equal(live.media_sequence, 2680, "live media_sequence")
assert_false(live.is_endlist, "live no endlist")
assert_equal(#live.segments, 3, "live segment count")


--------------------------------------------------------------------------------
-- 5. Encryption: IV, multi-key, METHOD=NONE
--------------------------------------------------------------------------------

section("Encryption: IV, multi-key, NONE method")

-- With IV
local key_iv_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:15
#EXT-X-ALLOW-CACHE:NO
#EXT-X-VERSION:2
#EXT-X-MEDIA-SEQUENCE:7794
#EXT-X-KEY:METHOD=AES-128,URI="/hls-key/key.bin",IV=0X10ef8f758ca555115584bb5b3c687f52
#EXTINF:15.0,
segment-7794.ts
#EXTINF:15.0,
segment-7795.ts
#EXT-X-ENDLIST
]]

local kiv, _ = parser.parse(key_iv_pl)
assert_equal(kiv.segments[1].key.method, "AES-128", "iv key method")
assert_equal(kiv.segments[1].key.uri, "/hls-key/key.bin", "iv key uri")
assert_equal(kiv.segments[1].key.iv, "0X10ef8f758ca555115584bb5b3c687f52", "iv hex value")
assert_equal(kiv.allow_cache, "NO", "allow_cache NO")

-- Multiple keys
local multi_key_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="/key1.bin",IV=0xABCD
#EXTINF:10.0,
segment-1.ts
#EXTINF:10.0,
segment-2.ts
#EXT-X-KEY:METHOD=AES-128,URI="/key2.bin",IV=0xCAFE
#EXTINF:10.0,
segment-3.ts
#EXT-X-ENDLIST
]]

local mk, _ = parser.parse(multi_key_pl)
assert_equal(#mk.keys, 2, "multi-key count")
assert_equal(mk.segments[1].key.uri, "/key1.bin", "seg1 key1")
assert_equal(mk.segments[2].key.uri, "/key1.bin", "seg2 key1")
assert_equal(mk.segments[3].key.uri, "/key2.bin", "seg3 key2")

-- METHOD=NONE without URI
local none_key_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="/key.bin"
#EXTINF:10.0,
seg1.ts
#EXTINF:10.0,
seg2.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:10.0,
seg3.ts
#EXT-X-ENDLIST
]]

local nk, _ = parser.parse(none_key_pl)
assert_equal(nk.segments[1].key.method, "AES-128", "none: seg1 encrypted")
assert_equal(nk.segments[3].key.method, "NONE", "none: seg3 NONE method")


--------------------------------------------------------------------------------
-- 6. SCTE35 / CUE-OUT / CUE-IN
--------------------------------------------------------------------------------

section("SCTE35 CUE-OUT / CUE-IN")

local cue_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.ts
#EXTINF:10.0,
seg2.ts
#EXT-X-CUE-OUT:DURATION=50.000
#EXTINF:10.0,
seg3.ts
#EXTINF:10.0,
seg4.ts
#EXT-X-CUE-IN
#EXTINF:10.0,
seg5.ts
#EXT-X-ENDLIST
]]

local cue, _ = parser.parse(cue_pl)
assert_true(cue.segments[3].cue_out, "cue_out on seg3")
assert_true(cue.segments[4].cue_out, "cue_out on seg4 (carried forward)")
assert_true(cue.segments[5].cue_in, "cue_in on seg5")
assert_nil(cue.segments[1].cue_out, "no cue_out on seg1")

-- CUE-OUT-CONT
local cue_cont_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-CUE-OUT:DURATION=50
#EXTINF:10.0,
seg1.ts
#EXT-X-CUE-OUT-CONT:ElapsedTime=5.000,Duration=50,SCTE35=/DAlAAAA
#EXTINF:10.0,
seg2.ts
#EXT-X-ENDLIST
]]

local cc, _ = parser.parse(cue_cont_pl)
assert_equal(cc.segments[2].scte35_elapsedtime, 5.0, "cue-out-cont elapsedtime")
assert_equal(cc.segments[2].scte35_duration, 50, "cue-out-cont duration")
assert_equal(cc.segments[2].scte35, "/DAlAAAA", "cue-out-cont SCTE35")


--------------------------------------------------------------------------------
-- 7. Variant attrs: CLOSED-CAPTIONS, video_range, HDCP-LEVEL, float bw
--------------------------------------------------------------------------------

section("Variant: CC, video_range, HDCP-LEVEL, float bw")

local cc_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,CODECS="avc1",CLOSED-CAPTIONS="cc",SUBTITLES="sub",AUDIO="aud"
variant1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,CODECS="avc1",CLOSED-CAPTIONS=NONE,AUDIO="aud"
variant2.m3u8
]]

local cc_data, _ = parser.parse(cc_pl)
assert_equal(cc_data.playlists[1].stream_info.closed_captions, "cc", "CC=cc")
assert_equal(cc_data.playlists[1].stream_info.audio, "aud", "audio group")
assert_equal(cc_data.playlists[2].stream_info.closed_captions, "NONE", "CC=NONE")

local vr_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,VIDEO-RANGE=SDR
sdr.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,VIDEO-RANGE=PQ
pq.m3u8
]]

local vr, _ = parser.parse(vr_pl)
assert_equal(vr.playlists[1].stream_info.video_range, "SDR", "video_range SDR")
assert_equal(vr.playlists[2].stream_info.video_range, "PQ", "video_range PQ")

local hdcp_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,HDCP-LEVEL=NONE
v1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,HDCP-LEVEL=TYPE-0
v2.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000,HDCP-LEVEL=TYPE-1
v3.m3u8
]]

local hdcp, _ = parser.parse(hdcp_pl)
assert_equal(hdcp.playlists[1].stream_info.hdcp_level, "NONE", "HDCP NONE")
assert_equal(hdcp.playlists[2].stream_info.hdcp_level, "TYPE-0", "HDCP TYPE-0")
assert_equal(hdcp.playlists[3].stream_info.hdcp_level, "TYPE-1", "HDCP TYPE-1")

-- Float bandwidth (truncated)
local fbw_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000.5
v1.m3u8
]]

local fbw, _ = parser.parse(fbw_pl)
assert_equal(fbw.playlists[1].stream_info.bandwidth, 1280000.5, "float bandwidth")


--------------------------------------------------------------------------------
-- 8. I-frame and Image playlists
--------------------------------------------------------------------------------

section("I-frame and Image playlists")

local iframe_pl = [[
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-I-FRAMES-ONLY
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.12,
#EXT-X-BYTERANGE:9400@376
segment1.ts
#EXT-X-ENDLIST
]]

local ifr, _ = parser.parse(iframe_pl)
assert_true(ifr.is_i_frames_only, "is_i_frames_only")
assert_equal(ifr.segments[1].duration, 4.12, "iframe duration")
assert_equal(ifr.segments[1].byterange.length, 9400, "iframe byterange length")
assert_equal(ifr.segments[1].byterange.offset, 376, "iframe byterange offset")

local image_pl = [[
#EXTM3U
#EXT-X-IMAGES-ONLY
#EXT-X-TILES:RESOLUTION=640x360,LAYOUT=5x2,DURATION=6.006
#EXTINF:6.006,
tile-0.jpg
#EXTINF:6.006,
tile-1.jpg
#EXT-X-ENDLIST
]]

local img, _ = parser.parse(image_pl)
assert_true(img.is_images_only, "is_images_only")
assert_not_nil(img.tiles, "tiles exist")
assert_equal(img.tiles.resolution, "640x360", "tiles resolution")
assert_equal(img.tiles.layout, "5x2", "tiles layout")


--------------------------------------------------------------------------------
-- 9. Multiple EXT-X-MAP (init section change)
--------------------------------------------------------------------------------

section("Multiple EXT-X-MAP (init section change)")

local multi_map_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MAP:URI="init1.mp4"
#EXTINF:10.0,
seg1.ts
#EXTINF:10.0,
seg2.ts
#EXT-X-MAP:URI="init2.mp4"
#EXTINF:10.0,
seg3.ts
#EXT-X-ENDLIST
]]

local mm, _ = parser.parse(multi_map_pl)
assert_equal(mm.segments[1].map.uri, "init1.mp4", "map seg1 init1")
assert_equal(mm.segments[2].map.uri, "init1.mp4", "map seg2 init1")
assert_equal(mm.segments[3].map.uri, "init2.mp4", "map seg3 init2")

-- MAP with BYTERANGE
local map_br_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MAP:URI="main.mp4",BYTERANGE="1200@0"
#EXTINF:10.0,
seg1.ts
#EXT-X-ENDLIST
]]

local mbr, _ = parser.parse(map_br_pl)
assert_equal(mbr.segments[1].map.uri, "main.mp4", "map with byterange uri")
assert_not_nil(mbr.segments[1].map.byterange, "map has byterange")
assert_equal(mbr.segments[1].map.byterange.length, 1200, "map byterange length")


--------------------------------------------------------------------------------
-- 10. EXT-X-MEDIA with channels, multiple session data
--------------------------------------------------------------------------------

section("MEDIA channels, multi-session-data")

local media_ch_pl = [[
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",CHANNELS="2",DEFAULT=YES,AUTOSELECT=YES,URI="audio-en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1280000,AUDIO="audio"
v1.m3u8
]]

local mch, _ = parser.parse(media_ch_pl)
assert_equal(mch.media[1].channels, 2, "media channels")

local multi_sd_pl = [[
#EXTM3U
#EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Title1",LANGUAGE="en"
#EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Title2",LANGUAGE="ru"
#EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Title3",LANGUAGE="de"
#EXT-X-SESSION-DATA:DATA-ID="com.example.uri",URI="http://example.com/data.json"
#EXT-X-STREAM-INF:BANDWIDTH=1280000
v1.m3u8
]]

local msd, _ = parser.parse(multi_sd_pl)
assert_equal(#msd.session_data, 4, "multi session data count")
assert_equal(msd.session_data[1].data_id, "com.example.title", "sd1 data_id")
assert_equal(msd.session_data[1].value, "Title1", "sd1 value")
assert_equal(msd.session_data[4].uri, "http://example.com/data.json", "sd4 uri")


--------------------------------------------------------------------------------
-- 11. EXT-X-START negative offset, GAP, BITRATE
--------------------------------------------------------------------------------

section("START neg offset, GAP, BITRATE")

local start_neg_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-START:TIME-OFFSET=-2.0
#EXTINF:10.0,
seg1.ts
#EXT-X-ENDLIST
]]

local sn, _ = parser.parse(start_neg_pl)
assert_equal(sn.start.time_offset, -2.0, "start negative time_offset")
assert_false(sn.start.precise, "start no precise")

local gap_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.ts
#EXT-X-GAP
#EXTINF:10.0,
seg2.ts
#EXT-X-GAP
#EXTINF:10.0,
seg3.ts
#EXTINF:10.0,
seg4.ts
#EXT-X-ENDLIST
]]

local gap, _ = parser.parse(gap_pl)
assert_false(gap.segments[1].gap, "gap seg1 false")
assert_true(gap.segments[2].gap, "gap seg2 true")
assert_true(gap.segments[3].gap, "gap seg3 true")
assert_false(gap.segments[4].gap, "gap seg4 false")

local br_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
#EXT-X-BITRATE:1674
seg1.ts
#EXTINF:10.0,
#EXT-X-BITRATE:1625
seg2.ts
#EXT-X-ENDLIST
]]

local brd, _ = parser.parse(br_pl)
assert_equal(brd.segments[1].bitrate, 1674, "bitrate seg1")
assert_equal(brd.segments[2].bitrate, 1625, "bitrate seg2")


--------------------------------------------------------------------------------
-- 12. Negative media sequence, discontinuity sequence
--------------------------------------------------------------------------------

section("Negative media_seq, discontinuity_seq")

local neg_seq_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:-2680\n#EXTINF:8.0,\nseg.ts\n"
local nseq, _ = parser.parse(neg_seq_pl)
assert_equal(nseq.media_sequence, -2680, "negative media_sequence")

local disc_seq_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-DISCONTINUITY-SEQUENCE:123\n#EXTINF:10.0,\nseg.ts\n#EXT-X-ENDLIST\n"
local dseq, _ = parser.parse(disc_seq_pl)
assert_equal(dseq.discontinuity_sequence, 123, "discontinuity_sequence")


--------------------------------------------------------------------------------
-- 13. Daterange variants: SCTE35-OUT/IN, END-ON-NEXT, in parts
--------------------------------------------------------------------------------

section("Daterange: SCTE35, END-ON-NEXT")

local dr_scte_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.ts
#EXT-X-DATERANGE:ID="ad1",START-DATE="2020-01-01T00:00:00Z",PLANNED-DURATION=59.993,SCTE35-OUT=0xFC302F0000
#EXTINF:10.0,
seg2.ts
#EXT-X-DATERANGE:ID="ad1",START-DATE="2020-01-01T00:00:00Z",DURATION=59.993,SCTE35-IN=0xFC302F0001
#EXTINF:10.0,
seg3.ts
#EXT-X-ENDLIST
]]

local drs, _ = parser.parse(dr_scte_pl)
assert_equal(#drs.segments[2].dateranges, 1, "dr scte: seg2 has daterange")
assert_equal(drs.segments[2].dateranges[1].scte35_out, "0xFC302F0000", "scte35-out")
assert_equal(drs.segments[3].dateranges[1].scte35_in, "0xFC302F0001", "scte35-in")

-- END-ON-NEXT
local dr_eon_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.ts
#EXT-X-DATERANGE:ID="test_id",CLASS="test_class",START-DATE="2020-03-10T07:48:02Z",END-ON-NEXT=YES
#EXTINF:10.0,
seg2.ts
#EXT-X-ENDLIST
]]

local dre, _ = parser.parse(dr_eon_pl)
assert_true(dre.segments[2].dateranges[1].end_on_next, "daterange end_on_next")


--------------------------------------------------------------------------------
-- 14. LL-HLS parts, preload hints, rendition reports, skip
--------------------------------------------------------------------------------

section("LL-HLS: parts, preload hints, skip dateranges")

local llhls_pl = [[
#EXTM3U
#EXT-X-VERSION:9
#EXT-X-TARGETDURATION:4
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,HOLD-BACK=6,PART-HOLD-BACK=3,CAN-SKIP-UNTIL=12
#EXT-X-PART-INF:PART-TARGET=1.0
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PART:DURATION=1.0,URI="part-1.ts",INDEPENDENT=YES
#EXT-X-PART:DURATION=1.0,URI="part-2.ts"
#EXTINF:4.0,
segment-1.ts
#EXT-X-DATERANGE:ID="ad1",CLASS="com.example.ad",START-DATE="2024-01-01T00:00:00Z",DURATION=30,PLANNED-DURATION=30,X-AD-ID=12345
#EXTINF:4.0,
segment-2.ts
#EXTINF:4.0,
segment-3.ts
#EXT-X-PRELOAD-HINT:TYPE=PART,URI="part-3.ts",BYTERANGE-START=0,BYTERANGE-LENGTH=100000
#EXT-X-RENDITION-REPORT:URI="variant.m3u8",LAST-MSN=3,LAST-PART=2
#EXT-X-SKIP:SKIPPED-SEGMENTS=5,RECENTLY-REMOVED-DATERANGES="1"
#EXT-X-ENDLIST
]]

local ll, _ = parser.parse(llhls_pl)
assert_equal(ll.version, 9, "LL-HLS version")
assert_not_nil(ll.part_inf, "part_inf exists")
assert_equal(ll.part_inf.part_target, 1.0, "part_target")
assert_not_nil(ll.server_control, "server_control exists")
assert_true(ll.server_control.can_block_reload, "can_block_reload")
assert_equal(ll.server_control.hold_back, 6, "hold_back")
assert_equal(ll.server_control.part_hold_back, 3, "part_hold_back")
assert_equal(ll.server_control.can_skip_until, 12, "can_skip_until")

local ll_seg1 = ll.segments[1]
assert_equal(#ll_seg1.parts, 2, "seg1 2 parts")
assert_equal(ll_seg1.parts[1].uri, "part-1.ts", "part 1 uri")
assert_true(ll_seg1.parts[1].independent, "part 1 independent")

local ll_seg2 = ll.segments[2]
assert_equal(#ll_seg2.dateranges, 1, "seg2 daterange")
assert_equal(ll_seg2.dateranges[1].id, "ad1", "daterange id")
assert_equal(ll_seg2.dateranges[1].class, "com.example.ad", "daterange class")
assert_equal(ll_seg2.dateranges[1].duration, 30, "daterange duration")
assert_equal(ll_seg2.dateranges[1].x_attributes.ad_id, 12345, "daterange x-ad-id")

assert_not_nil(ll.preload_hint, "preload_hint exists")
assert_equal(ll.preload_hint.hint_type, "PART", "preload hint type")
assert_equal(ll.preload_hint.uri, "part-3.ts", "preload hint uri")
assert_equal(ll.preload_hint.byterange_start, 0, "preload hint start")
assert_equal(ll.preload_hint.byterange_length, 100000, "preload hint length")

assert_equal(#ll.rendition_reports, 1, "rendition report count")
assert_equal(ll.rendition_reports[1].uri, "variant.m3u8", "rendition report uri")
assert_equal(ll.rendition_reports[1].last_msn, 3, "rendition report last_msn")
assert_equal(ll.rendition_reports[1].last_part, 2, "rendition report last_part")

assert_not_nil(ll.skip, "skip exists")
assert_equal(ll.skip.skipped_segments, 5, "skipped_segments")
assert_equal(ll.skip.recently_removed_dateranges, 1, "recently_removed_dateranges")


--------------------------------------------------------------------------------
-- 15. Content steering, session data/key
--------------------------------------------------------------------------------

section("Content steering, session data/key")

local steering_pl = [[
#EXTM3U
#EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example.com/api",PATHWAY-ID="CDN-A"
#EXT-X-SESSION-DATA:DATA-ID="session1",VALUE="some-data"
#EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://example.com/session-key.bin",IV=0xABCD
#EXT-X-STREAM-INF:BANDWIDTH=1280000,PATHWAY-ID="CDN-A"
v1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,PATHWAY-ID="CDN-B"
v2.m3u8
]]

local st, _ = parser.parse(steering_pl)
assert_not_nil(st.content_steering, "content_steering exists")
assert_equal(st.content_steering.server_uri, "https://steering.example.com/api", "server_uri")
assert_equal(st.content_steering.pathway_id, "CDN-A", "pathway_id")
assert_equal(#st.session_data, 1, "session data count")
assert_equal(st.session_data[1].data_id, "session1", "session_data data_id")
assert_equal(#st.session_keys, 1, "session keys count")
assert_equal(st.session_keys[1].method, "AES-128", "session_key method")
assert_equal(st.session_keys[1].iv, "0xABCD", "session_key iv")


--------------------------------------------------------------------------------
-- 16. Stable variant/rendition IDs, REQ-VIDEO-LAYOUT
--------------------------------------------------------------------------------

section("Stable ID, REQ-VIDEO-LAYOUT")

local svid_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,STABLE-VARIANT-ID="eb9c6e4de930b36d9a67fbd38a30b39f865d98f4a203d2140bbf71fd58ad764e"
v1.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50000,STABLE-VARIANT-ID="415901312adff69b967a0644a54f8d00dc14004f36bc8293737e6b4251f60f3f",URI="iframes.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",STABLE-RENDITION-ID="a8213e27c12a158ea8660e0fe8bdcac6072ca26d984e7e8603652bc61fdceffa",URI="audio.m3u8"
]]

local sv, _ = parser.parse(svid_pl)
assert_equal(sv.playlists[1].stream_info.stable_variant_id, "eb9c6e4de930b36d9a67fbd38a30b39f865d98f4a203d2140bbf71fd58ad764e", "stable-variant-id")
assert_equal(sv.iframe_playlists[1].stream_info.stable_variant_id, "415901312adff69b967a0644a54f8d00dc14004f36bc8293737e6b4251f60f3f", "iframe stable-variant-id")
assert_equal(sv.media[1].stable_rendition_id, "a8213e27c12a158ea8660e0fe8bdcac6072ca26d984e7e8603652bc61fdceffa", "stable-rendition-id")

local rvl_pl = [[
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,REQ-VIDEO-LAYOUT="CH-STEREO"
v1.m3u8
]]

local rvl, _ = parser.parse(rvl_pl)
assert_equal(rvl.playlists[1].stream_info.req_video_layout, "CH-STEREO", "req_video_layout")


--------------------------------------------------------------------------------
-- 17. Keyformat and keyformatversions
--------------------------------------------------------------------------------

section("Keyformat / keyformatversions")

local kf_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="/key.bin",KEYFORMAT="identity",KEYFORMATVERSIONS="1"
#EXTINF:10.0,
seg1.ts
#EXT-X-ENDLIST
]]

local kf, _ = parser.parse(kf_pl)
assert_equal(kf.segments[1].key.keyformat, "identity", "keyformat")
assert_equal(kf.segments[1].key.keyformatversions, 1, "keyformatversions")


--------------------------------------------------------------------------------
-- 18. Mixed content (non-strict) and error handling
--------------------------------------------------------------------------------

section("Mixed content and error handling")

-- Messy content in non-strict mode
local messy_pl = [[
#EXTM3U
#EXT-X-TARGETDURATION:10
JUNK
#EXTINF:10.0,
segment.ts
#EXT-X-ENDLIST
]]

local messy, _ = parser.parse(messy_pl, false)
assert_not_nil(messy, "messy parsed non-strict")
assert_equal(#messy.segments, 1, "messy segment count")
assert_equal(messy.segments[1].uri, "segment.ts", "messy segment uri")

-- Strict mode: bad first line
local _, err1 = parser.parse("not m3u8 content")
assert_not_nil(err1, "bad first line error")

-- Strict mode: unknown tag
local _, err2 = parser.parse("#EXTM3U\n#EXT-X-UNKNOWN-TAG:value", true)
assert_not_nil(err2, "unknown tag strict error")

-- Non-strict: unknown tag ok
local data3, err3 = parser.parse("#EXTM3U\n#EXT-X-UNKNOWN-TAG:value", false)
assert_not_nil(data3, "unknown tag non-strict ok")
assert_equal(err3, nil, "non-strict no error")

-- Empty content
local _, err4 = parser.parse("")
assert_not_nil(err4, "empty content error")


--------------------------------------------------------------------------------
-- 19. Round-trip tests
--------------------------------------------------------------------------------

section("Round-trip")

-- Media playlist round-trip
local rt1, _ = m3u8.loads(media_playlist)
assert_not_nil(rt1, "loads media playlist")

local dumped1 = rt1:dumps()
assert_not_nil(dumped1, "dumps returned string")

local rt2, _ = m3u8.loads(dumped1)
assert_not_nil(rt2, "re-parse succeeded")
assert_equal(#rt2.segments, 3, "re-parse segment count")
assert_equal(rt2.segments[1].uri, "segment-1.ts", "re-parse seg1 uri")
assert_equal(rt2.segments[1].duration, 10.0, "re-parse seg1 duration")
assert_equal(rt2.target_duration, 10, "re-parse target_duration")
assert_equal(rt2.is_endlist, true, "re-parse endlist")

-- Master playlist round-trip
local master_playlist = [[
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio-en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="Spanish",LANGUAGE="es",DEFAULT=NO,AUTOSELECT=NO,URI="audio-es.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="subs-en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30,AUDIO="audio-aac",SUBTITLES="subs"
1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="avc1.64001e,mp4a.40.2",RESOLUTION=854x480,FRAME-RATE=30,AUDIO="audio-aac",SUBTITLES="subs"
480p.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50000,CODECS="avc1.640028",RESOLUTION=1920x1080,URI="iframes-1080p.m3u8"
]]

local mrt1, _ = m3u8.loads(master_playlist)
assert_not_nil(mrt1, "loads master playlist")

local dm = mrt1:dumps()
assert_not_nil(dm, "master dumps returned string")

local mrt2, _ = m3u8.loads(dm)
assert_not_nil(mrt2, "master re-parse succeeded")
assert_equal(#mrt2.playlists, 2, "master re-parse variant count")
assert_equal(#mrt2.media, 3, "master re-parse media count")
assert_equal(#mrt2.iframe_playlists, 1, "master re-parse iframe count")
assert_equal(mrt2.playlists[1].uri, "1080p.m3u8", "master re-parse uri")

-- Live playlist round-trip (should NOT add ENDLIST)
local rt_live, _ = m3u8.loads(live_pl)
assert_not_nil(rt_live, "live loads")
assert_false(rt_live.is_endlist, "live no endlist before dump")
local live_dumped = rt_live:dumps()
assert_false(string.find(live_dumped, "#EXT-X-ENDLIST") ~= nil, "live dump has no ENDLIST")

-- Dump ends with newline
assert_equal(string.sub(dumped1, -1), "\n", "dump ends with newline")


--------------------------------------------------------------------------------
-- 20. Key change detection in dumps
--------------------------------------------------------------------------------

section("Dumps: key change and multi-key")

-- Round-trip with multi-key
local mk_rt1, _ = m3u8.loads(multi_key_pl)
assert_not_nil(mk_rt1, "multi-key loads")
local mk_dumped = mk_rt1:dumps()

local mk_rt2, _ = m3u8.loads(mk_dumped)
assert_equal(#mk_rt2.segments, 3, "multi-key re-parse segs")
assert_equal(#mk_rt2.keys, 2, "multi-key re-parse keys")
assert_equal(mk_rt2.segments[1].key.uri, "/key1.bin", "multi-key re-parse seg1 key")
assert_equal(mk_rt2.segments[3].key.uri, "/key2.bin", "multi-key re-parse seg3 key")

-- NONE method key round-trip
local nk_rt1, _ = m3u8.loads(none_key_pl)
local nk_dumped = nk_rt1:dumps()
local nk_rt2, _ = m3u8.loads(nk_dumped)
assert_equal(nk_rt2.segments[3].key.method, "NONE", "NONE key re-parse")


--------------------------------------------------------------------------------
-- 21. Dumps with endlist on/off, program_date_time, discontinuity
--------------------------------------------------------------------------------

section("Dumps: endlist, PDT, discontinuity")

-- ENDLIST on
local endlist_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,\nseg.ts\n#EXT-X-ENDLIST\n"
local el1, _ = m3u8.loads(endlist_pl)
local el_dump = el1:dumps()
assert_true(string.find(el_dump, "#EXT-X-ENDLIST", 1, true) ~= nil, "dump has ENDLIST")

-- ENDLIST off (live)
local noel_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:8.0,\nseg.ts\n"
local nel1, _ = m3u8.loads(noel_pl)
local nel_dump = nel1:dumps()
assert_false(string.find(nel_dump, "#EXT-X-ENDLIST") ~= nil, "dump has no ENDLIST for live")

-- Program date time in dump
local pdt_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:00Z\n#EXTINF:10.0,\nseg.ts\n#EXT-X-ENDLIST\n"
local pdt1, _ = m3u8.loads(pdt_pl)
local pdt_dump = pdt1:dumps()
assert_true(string.find(pdt_dump, "#EXT-X-PROGRAM-DATE-TIME", 1, true) ~= nil, "dump has program-date-time")

-- Discontinuity in dump
local disc_pl = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nseg1.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10.0,\nseg2.ts\n#EXT-X-ENDLIST\n"
local disc1, _ = m3u8.loads(disc_pl)
local disc_dump = disc1:dumps()
assert_true(string.find(disc_dump, "#EXT-X-DISCONTINUITY", 1, true) ~= nil, "dump has DISCONTINUITY")


--------------------------------------------------------------------------------
-- 22. Dumps: VARIANT round-trips
--------------------------------------------------------------------------------

section("Dumps: variant round-trips")

-- Variant with VIDEO-RANGE
local vr1, _ = m3u8.loads(vr_pl)
local vr_dump = vr1:dumps()
local vr2, _ = m3u8.loads(vr_dump)
assert_equal(vr2.playlists[1].stream_info.video_range, "SDR", "vr re-parse SDR")
assert_equal(vr2.playlists[2].stream_info.video_range, "PQ", "vr re-parse PQ")

-- Variant with HDCP-LEVEL
local hdcp1, _ = m3u8.loads(hdcp_pl)
local hdcp_dump = hdcp1:dumps()
local hdcp2, _ = m3u8.loads(hdcp_dump)
assert_equal(hdcp2.playlists[1].stream_info.hdcp_level, "NONE", "hdcp re-parse NONE")
assert_equal(#hdcp2.playlists, 3, "hdcp re-parse 3 variants")

-- Content steering round-trip
local st1, _ = m3u8.loads(steering_pl)
local st_dump = st1:dumps()
local st2, _ = m3u8.loads(st_dump)
assert_not_nil(st2.content_steering, "steering re-parse exists")
assert_equal(st2.content_steering.server_uri, "https://steering.example.com/api", "steering re-parse uri")


--------------------------------------------------------------------------------
-- 23. Results
--------------------------------------------------------------------------------

section("Results")

print(string.format("PASS: %d  FAIL: %d  TOTAL: %d", passed, failed, passed + failed))

if failed > 0 then
    os.exit(1)
end
