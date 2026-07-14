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
