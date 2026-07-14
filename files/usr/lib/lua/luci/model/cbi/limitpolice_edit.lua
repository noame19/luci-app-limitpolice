-- luci-app-limitpolice - single-rule edit form (extedit target)
-- Reached via /admin/network/limitpolice/edit/<section-id>
-- arg[1] carries the section id from the URL %s placeholder.

local fs  = require "nixio.fs"
local dispatcher = require "luci.dispatcher"

local m = Map("limitpolice",
    translate("Edit rule"),
    translate("Edit a single per-device bandwidth rule. "
        .. "Save & Apply will restart the init script."))

-- Bind the Map to the section id supplied by the dispatcher.
if arg and arg[1] then
    m:set(arg[1])
end

m.template = "cbi/map"

local s = m:section(TypedSection, "rule", translate("Rule"))
s.anonymous = true
s.addremove = false      -- manage rows on the main page; this view only edits
s.extedit   = nil        -- no nested extedit

local r_en = s:option(Flag, "enabled", translate("Enable"))
r_en.rmempty = false
r_en.default = "1"

local r_if = s:option(ListValue, "interface", translate("Interface"))
r_if.default = "br-lan"
local seen = {}
local function add_iface(name)
    if name and name ~= "" and not seen[name] then
        seen[name] = true
        r_if:value(name, name)
    end
end
add_iface("br-lan")
if fs.access("/sys/class/net") then
    for i in fs.dir("/sys/class/net") do
        if i ~= "lo" and not i:match("^ifb") and not i:match("_ifb$")
           and not i:match("^gre") and not i:match("^tun")
           and not i:match("^wg") and not i:match("^tailscale") then
            add_iface(i)
        end
    end
end

local r_tt = s:option(ListValue, "target_type", translate("Match by"))
r_tt:value("ip",  "IP / CIDR")
r_tt:value("mac", "MAC address")
r_tt.default = "ip"

local r_t = s:option(Value, "target", translate("Target"))
r_t.rmempty = false
r_t.placeholder = "192.168.1.100/32 or aa:bb:cc:dd:ee:ff"
r_t.description = translate("Either an IPv4/CIDR or a colon-separated MAC.")

local r_dir = s:option(ListValue, "direction", translate("Direction"))
r_dir:value("dst", translate("Downlink (to this device)"))
r_dir:value("src", translate("Uplink (from this device)"))
r_dir.default = "dst"
r_dir.description = translate(
    "<b>dst</b> caps packets <em>to</em> the device → pair with a WAN-side iface "
    .. "(e.g. <code>wan</code>, <code>pppoe-wan</code>, <code>eth1</code>).<br/>"
    .. "<b>src</b> caps packets <em>from</em> the device → pair with a LAN-side iface "
    .. "(e.g. <code>br-lan</code>, <code>eth0</code>).<br/>"
    .. "Wrong pairing = rule matches zero packets = silently wasted slot.")

local r_rate = s:option(Value, "rate", translate("Rate"))
r_rate.rmempty = false
r_rate.datatype = "uinteger"
r_rate.default = "10"
r_rate.placeholder = "10"

local r_unit = s:option(ListValue, "unit", translate("Unit"))
r_unit:value("Kbps", translate("Kbps (kilobits per second)"))
r_unit:value("Mbps", translate("Mbps (megabits per second)"))
r_unit:value("KB/s", translate("KB/s (kilobytes per second)"))
r_unit:value("MB/s", translate("MB/s (megabytes per second)"))
r_unit.default = "Mbps"

local r_q = s:option(Value, "quota", translate("Daily quota (0 = off)"))
r_q.datatype = "uinteger"
r_q.default  = "0"
r_q.placeholder = "0"
r_q.description = translate("When exceeded, this device's filter is dropped to the "
    .. "throttle rate configured in the main section until the next 00:00 reset. "
    .. "Counted from <code>tc -s filter show</code> bytes.")

local r_qu = s:option(ListValue, "quota_unit", translate("Quota unit"))
r_qu:value("KB", "KB")
r_qu:value("MB", "MB")
r_qu:value("GB", "GB")
r_qu:value("TB", "TB")
r_qu.default = "MB"

local r_c = s:option(Value, "comment", translate("Note"))
r_c.rmempty = true
r_c.placeholder = "iphone, smart-tv, …"

-- After Save & Apply, send user back to the main table.
function m.on_after_commit(self)
    luci.http.redirect(dispatcher.build_url("admin/network/limitpolice"))
end

return m