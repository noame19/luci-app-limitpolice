module("luci.controller.limitpolice", package.seeall)

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

function index()
    entry({"admin", "network", "limitpolice"},
          cbi("limitpolice"),
          _("Limit Police"), 80).acl_depends = { "access_ssh" }

    entry({"admin", "network", "limitpolice", "pick"},
          call("action_pick")).leaf = true

    entry({"admin", "network", "limitpolice", "service"},
          call("action_service")).leaf = true

    -- Single-rule edit page (extedit target).
    -- %s is the section id (e.g. @rule[0]) from the URL.
    entry({"admin", "network", "limitpolice", "edit", "%s"},
          cbi("limitpolice_edit"),
          _("Edit rule"), nil).leaf = true

    -- Traffic statistics report — read-only view backed by /tmp files
    -- maintained by limitpolice-quota-check every 5 minutes. The route
    -- is registered unconditionally but no background process exists;
    -- opening the tab is what forks the template renderer.
    entry({"admin", "network", "limitpolice", "stats"},
          call("action_stats"),
          _("Traffic Report"), 81).acl_depends = { "access_ssh" }
end

-- Handle GET ?pick=IP|MAC&section=@rule[N]&target_type=ip|mac
function action_pick()
    local pick   = http.formvalue("pick")
    local target_type = http.formvalue("target_type") or "ip"
    local section = http.formvalue("section")
    if not (pick and section and section:match("^@rule%[[0-9]+%]$")) then
        http.status(400, "Bad Request")
        return
    end
    uci:set("limitpolice", section, "target_type", target_type)
    uci:set("limitpolice", section, "target", pick)
    uci:save("limitpolice")
    uci:commit("limitpolice")
    http.redirect(dispatcher.build_url("admin/network/limitpolice"))
end

-- Service control: ?service=start|stop|restart|reload
function action_service()
    local svc = http.formvalue("service")
    if svc and svc:match("^(start|stop|restart|reload|enable|disable)$") then
        sys.call("/etc/init.d/limitpolice " .. svc .. " >/dev/null 2>&1")
        if svc == "enable" or svc == "disable" then
            uci:set("limitpolice", "@main[0]", "enabled", svc == "enable" and "1" or "0")
            uci:save("limitpolice"); uci:commit("limitpolice")
        end
    end
    http.redirect(dispatcher.build_url("admin/network/limitpolice"))
end

-- Render the traffic report. Reads everything from /tmp and /var/run in
-- the request handler so the view template is dumb HTML.
function action_stats()
    local fs = require "nixio.fs"

    -- 1. DHCP leases → mac/ip/name for table population + hostname column.
    local leases = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local ts, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
            if ts and mac and ip then
                if name == nil or name == "" or name == "*" then name = "(no name)" end
                leases[mac] = { ip = ip, name = name }
                leases[ip]  = { ip = ip, name = name, mac = mac }
            end
        end
        f:close()
    end

    -- 2. Stats files keyed by MAC (or ip-X.X.X.X for unknown devices).
    local rows = {}
    local stats_dir = "/tmp/limitpolice/stats"
    local stats_it, stats_err = fs.dir(stats_dir)
    if stats_it then
        for id in stats_it do
            -- skip .lock and other dotfiles
            if id:sub(1, 1) ~= "." then
                local path = stats_dir .. "/" .. id
                local sf = io.open(path, "r")
                if sf then
                    local row = { id = id }
                    for line in sf:lines() do
                        local k, v = line:match("^([^=]+)=(.*)$")
                        if k and v then row[k] = v end
                    end
                    sf:close()
                    -- Lookup DHCP hostname/IP if known.
                    local lease = {}
                    if id:match(":") then lease = leases[id] or {} end
                    row.name = row.name or lease.name or "(unknown)"
                    row.ip   = row.ip   or lease.ip   or "—"
                    row.is_mac = id:match(":") and true or false
                    rows[#rows + 1] = row
                end
            end
        end
    end
    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

    -- 3. Quick-action URLs reuse action_pick: each row gets "add limit"
    -- and "add quota" buttons that pre-fill a new rule via the pick
    -- mechanism (jump to the main page; user picks Save & Apply).
    local function pick_url(target, target_type)
        return dispatcher.build_url("admin/network/limitpolice/pick")
            .. "?pick=" .. http.urlencode(target)
            .. "&target_type=" .. target_type
            .. "&section=@rule[0]"
    end
    for _, r in ipairs(rows) do
        r.limit_url = r.is_mac and pick_url(r.id, "mac")
                                   or pick_url(r.ip, "ip")
        r.ip_url    = r.ip ~= "—" and pick_url(r.ip, "ip") or r.limit_url
    end

    luci.template.render("limitpolice_stats", {
        rows    = rows,
        now     = os.time(),
        stats_dir_exists = stats_it ~= nil,
    })
end
