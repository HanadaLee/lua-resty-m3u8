use strict;
use warnings FATAL => 'all';
use Cwd qw(abs_path);
use Test::Nginx::Socket::Lua;

my $lib = $ENV{TEST_NGINX_M3U8_LIB} || abs_path('lib');
$lib =~ s{\\}{/}g;

plan tests => blocks() * 2;

our $HttpConfig = qq{
    lua_package_path "$lib/?.lua;$lib/?/init.lua;;";
};

run_tests();

__DATA__

=== TEST 1: quoted string attributes and permissive default
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local content = [[
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="00123",NAME="00123",URI="00123/audio.m3u8"
#EXT-X-UNKNOWN:ignored
]]
            local data, err = m3u8.parse(content)
            local strict_data, strict_err = m3u8.parse(content, true)
            ngx.say(data.media[1].group_id, ":", type(data.media[1].group_id))
            ngx.say(data.media[1].uri, ":", type(data.media[1].uri))
            ngx.say(tostring(strict_data), ":", strict_err:find("unknown tag", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
00123:string
00123/audio.m3u8:string
nil:true
--- no_error_log


=== TEST 2: LL-HLS parts survive EXTINF and trailing partial segments
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local playlist = assert(m3u8.loads([[#EXTM3U
#EXT-X-PART:DURATION=0.5,URI="part-0.m4s"
#EXTINF:1,
segment-0.m4s
#EXT-X-PART:DURATION=0.5,URI="part-1.m4s"
]]))
            ngx.say(#playlist.segments, ":", #playlist.segments[1].parts)
            ngx.say(playlist:dumps():find("#EXTINF:0", 1, true) == nil)
        }
    }
--- request
GET /t
--- response_body
2:1
true
--- no_error_log


=== TEST 3: EXT-X-MAP is emitted once per map change
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local playlist = assert(m3u8.loads([[#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="init-a.mp4"
#EXTINF:1,
a.m4s
#EXTINF:1,
b.m4s
#EXT-X-MAP:URI="init-b.mp4"
#EXTINF:1,
c.m4s
]]))
            local output = playlist:dumps()
            local _, a = output:gsub("#EXT-X-MAP:URI=\"init%-a%.mp4\"", "")
            local _, b = output:gsub("#EXT-X-MAP:URI=\"init%-b%.mp4\"", "")
            ngx.say(a, ":", b)
        }
    }
--- request
GET /t
--- response_body
1:1
--- no_error_log


=== TEST 4: master playlist keeps target duration during serialization
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local playlist = assert(m3u8.loads([[#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="aud"
video.m3u8
]]))
            ngx.say(playlist.is_variant, ":", playlist.target_duration)
            local output = playlist:dumps()
            ngx.say(output:find("#EXT-X-TARGETDURATION:6", 1, true) ~= nil)
            local _, audio_count = output:gsub("AUDIO=", "")
            ngx.say(audio_count == 1)
        }
    }
--- request
GET /t
--- response_body
true:6
true
true
--- no_error_log


=== TEST 5: strict mode rejects an unexpected URI line
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local playlist, err = m3u8.loads([[#EXTM3U
orphan.ts
]], true)
            ngx.say(tostring(playlist), ":", err:find("syntax error on line 2", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
nil:true
--- no_error_log


=== TEST 6: strict mode rejects malformed EXTINF
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local m3u8 = require "resty.m3u8"
            local playlist, err = m3u8.loads([[#EXTM3U
#EXTINF:1
segment.ts
]], true)
            ngx.say(tostring(playlist), ":", err:find("EXTINF without comma", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
nil:true
--- no_error_log
