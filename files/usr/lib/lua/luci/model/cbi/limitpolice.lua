-- luci-app-limitpolice — CBI form
-- Compatible with OpenWrt 18.06 (Lua 5.1 + luci.cbi) through 24.10.

local fs  = require "nixio.fs"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local uci  = require "luci.model.uci".cursor()
local http = require "luci.http"

-- ---------- helpers --------------------------------------------------------

-- Parse /tmp/dhcp.leases: each line is "<expiry> <mac> <ip> <hostname>".
local DHCP_LEASES = "/tmp/dhcp.leases"

local function parse_leases()
    local rv = {}
    local f = io.open(DHCP_LEASES, "r")
    if not f then return rv end
    for line in f:lines() do
        local ts, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
        if ts and mac and ip then
            if name == nil or name == "" or name == "*" then
                name = "(no name)"
            end
            rv[#rv + 1] = { ts = ts, ip = ip, mac = mac, name = name }
        end
    end
    f:close()
    table.sort(rv, function(a, b) return a.name < b.name end)
    return rv
end

local leases = parse_leases()

-- Build an option with every network device on the system.
local function list_ifaces()
    local out = {}
    for i in fs.dir("/sys/class/net") do
        if i ~= "lo" and not i:match("^ifb") and not i:match("_ifb$")
           and not i:match("^gre") and not i:match("^tun")
           and not i:match("^wg") and not i:match("^tailscale") then
            out[#out + 1] = i
        end
    end
    table.sort(out)
    return out
end

-- ---------- map ------------------------------------------------------------

local m = Map("limitpolice",
    translate("Limit Police"),
    translate("Per-device bandwidth policing using <code>tc ingress police</code>. "
        .. "Stays compatible with hardware Flow Offloading, fullcon NAT, and BBR. "
        .. "No IFB, no HTB, no fq_codel, no Cake."))

m.template = "cbi/map"

-- Main section ----------------------------------------------------------
local main = m:section(SimpleSection, "limitpolice", translate("Service"))
main.anonymous = true

local en = main:option(Flag, "enabled", translate("Enable service"))
en.rmempty = false
en.default = "0"
en.description = translate("When enabled, rules below are pushed via <code>/etc/init.d/limitpolice</code>.")

-- Service action buttons ------------------------------------------------
local actions = main:option(DummyValue, "_actions", translate("Service control"))
function actions.cfgvalue()
    local out = '<div class="lp-actions">'
    local s = {
        { id = "start",   label = "Start"   },
        { id = "stop",    label = "Stop"    },
        { id = "restart", label = "Restart" },
        { id = "reload",  label = "Reload"  },
    }
    for _, b in ipairs(s) do
        local url = dispatcher.build_url("admin/network/limitpolice/service") ..
                    "?service=" .. b.id
        out = out .. string.format(
            '<a class="lp-btn" href="%s">%s</a> ', url, b.label)
    end
    out = out .. '</div>'
    return out
end

-- Status dump -----------------------------------------------------------
local status_v = main:option(DummyValue, "_status", translate("Current status"))
function status_v.cfgvalue()
    local code = util.exec("/etc/init.d/limitpolice status 2>&1")
    code = code or "(no output)"
    return '<pre class="lp-status">' .. code:gsub("[<>&]", {
        ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;",
    }) .. '</pre>'
end

-- Rules section ---------------------------------------------------------
local rules = m:section(TypedSection, "rule", translate("Per-device rules"))
rules.anonymous = true
rules.addremove = true
rules.template = "cbi/tblsection"
rules.extedit = dispatcher.build_url("admin/network/limitpolice/edit/%s")

local r_en = rules:option(Flag, "enabled", translate("Enable"))
r_en.rmempty = false
r_en.default = "1"

local r_if = rules:option(ListValue, "interface", translate("Interface"))
r_if:value("br-lan", "br-lan (LAN bridge, common case)")
for _, name in ipairs(list_ifaces()) do
    r_if:value(name, name)
end
r_if.default = "br-lan"

local r_tt = rules:option(ListValue, "target_type", translate("Match by"))
r_tt:value("ip",  "IP / CIDR")
r_tt:value("mac", "MAC address")
r_tt.default = "ip"

local r_t = rules:option(Value, "target", translate("Target"))
r_t.rmempty = false
r_t.placeholder = "192.168.1.100/32 or aa:bb:cc:dd:ee:ff"
r_t.description = translate("Either type a value above, or click a chip below.")

local r_dir = rules:option(ListValue, "direction", translate("Direction"))
r_dir:value("dst", translate("Downlink (to this device)"))
r_dir:value("src", translate("Uplink (from this device)"))
r_dir.default = "dst"

local r_rate = rules:option(Value, "rate", translate("Rate"))
r_rate.rmempty = false
r_rate.datatype = "uinteger"
r_rate.default = "10"
r_rate.placeholder = "10"

local r_unit = rules:option(ListValue, "unit", translate("Unit"))
r_unit:value("Kbps", translate("Kbps (kilobits per second)"))
r_unit:value("Mbps", translate("Mbps (megabits per second)"))
r_unit:value("KB/s", translate("KB/s (kilobytes per second)"))
r_unit:value("MB/s", translate("MB/s (megabytes per second)"))
r_unit.default = "Mbps"

local r_c = rules:option(Value, "comment", translate("Note"))
r_c.placeholder = "iphone, smart-tv, …"
r_c.rmempty = true

-- DHCP picker (chips with quick-fill links)
local picker = rules:option(DummyValue, "_picker", translate("Pick from DHCP"))
function picker.cfgvalue(self, section)
    if #leases == 0 then
        return '<em class="lp-muted">' ..
            translate("No DHCP leases found at /tmp/dhcp.leases.") .. '</em>'
    end
    local base = dispatcher.build_url("admin/network/limitpolice/pick")
    local out = '<div class="lp-picker">'
    for _, l in ipairs(leases) do
        local url_ip = string.format(
            "%s?pick=%s&target_type=ip&section=%s",
            base, l.ip, section)
        local url_mac = string.format(
            "%s?pick=%s&target_type=mac&section=%s",
            base, l.mac, section)
        out = out .. string.format(
            '<span class="lp-chip-group">' ..
              '<a class="lp-chip" href="%s" title="%s">%s &middot; %s</a>' ..
              '<a class="lp-chip lp-chip-mac" href="%s" title="MAC">MAC</a>' ..
            '</span> ',
            url_ip, l.mac, l.name, l.ip, url_mac)
    end
    out = out .. '</div>'
    return out
end

return m
