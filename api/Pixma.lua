local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local Xml = require("mod.extlibs.api.Xml")
local Ivec = require("mod.pixma.api.pixma.Ivec")

local Pixma = class.class("Pixma")

--- Splits a string `str` on separator `sep`.
---
--- @tparam string str
--- @tparam[opt] string sep defaults to "\n"
--- @treturn {string}
function string.split(str,sep)
   sep = sep or "\n"
   local ret={}
   local n=1
   for w in str:gmatch("([^"..sep.."]*)") do
      ret[n] = ret[n] or w
      if w=="" then
         n = n + 1
      end
   end
   return ret
end

function string.lines(s)
   if string.sub(s, -1) ~= "\n" then s = s .. "\n" end
   return string.gmatch(s, "(.-)\n")
end

local function build_headers(headers)
   local s = ""
   for k, v in pairs(headers) do
      s = s .. ("%s: %s\r\n"):format(k, v)
   end
   return s
end

local function build_one_request(request, host)
   request.headers = request.headers or {}
   request.headers["Host"] = host
   request.headers["X-CHMP-Version"] = "1.3.0"
   if request.data then
      request.headers["Content-Length"] = request.data:len()
   end
   local headers = build_headers(request.headers)
   return ("%s %s HTTP/1.1\r\n%s\r\n%s")
      :format(request.method, request.path, headers, request.data or "")
end

local function shouldredirect(reqt, code, headers)
   return headers.location and
      string.gsub(headers.location, "%s", "") ~= "" and
      (reqt.redirect ~= false) and
      (code == 301 or code == 302 or code == 303 or code == 307) and
      (not reqt.method or reqt.method == "GET" or reqt.method == "HEAD")
      and headers["content-type"]
      and (not reqt.nredirects or reqt.nredirects < 5)
end

local function shouldreceivebody(reqt, code, headers)
   if reqt.method == "HEAD" then return nil end
   if code == 204 or code == 304 then return nil end
   if code >= 100 and code < 200 then return nil end
   if not headers["content-type"] then return nil end
   return 1
end

function Pixma:_request(r)
   local host = self.host
   local port = 80

   local t = {}
   local nreqt = {
      sink = ltn12.sink.table(t)
   }

   local h = http.open(host, port, nil)

   h.c:settimeout(1)
   for i, v in ipairs(r) do
      -- Oh my fuck.
      --
      -- The response depends on the first POST request first calculating the
      -- data to send back to the client, then being returned in the next GET
      -- request. If you send both requests too soon, the second will return 204
      -- (No Content), presumably because the server has not finished computing
      -- things yet.
      --
      -- This is totally unlike how HTTP should be used as a request/response
      -- protocol.
      if i > 1 then
         socket.sleep(0.5)
      end

      h.c:send(build_one_request(v, host))
   end

   print("=================")
   local code, status, headers
   for i = 1, #r do
      headers = nil
      -- send request line and headers
      code, status = h:receivestatusline()
      print("status", code, status)
      -- if it is an HTTP/0.9 server, simply get the body and we are done
      if not code then
         h:receive09body(status, nreqt.sink, nreqt.step)
         return 1, 200
      end

      -- ignore any 100-continue messages
      while code == 100 do
         headers = h:receiveheaders()
         code, status = h:receivestatusline()
      end
      headers = h:receiveheaders()
      -- at this point we should have a honest reply from the server
      -- we can't redirect if we already used the source, so we report the error
      if shouldredirect(nreqt, code, headers) and not nreqt.source then
         h:close()
         return 1, code, headers, status, table.concat(t)
      end

      -- here we are finally done
      if shouldreceivebody(nreqt, code, headers) then
         h:receivebody(headers, nreqt.sink, nreqt.step)
      end
   end
   h:close()
   return 1, code, headers, status, table.concat(t)
end

Pixma.request = socket.protect(Pixma._request)

function Pixma:init(host)
   self.host = host
end

function Pixma:get_device_id()
   local r = {
      {
         method = "GET",
         path = "/canon/ij/command1/port1",
         headers = {
            ["X-CHMP-Property"] = "DeviceID(Print)",
         },
      },
   }

   local ok, code, headers, status, text = assert(self:request(r))
   local id = {}
   if code == 200 then
      local parsed = text:sub(3):split(";")
      for i, v in ipairs(parsed) do
         local pair = v:split(":")
         id[pair[1]] = pair[2]
      end
   end
   return id, code
end

function Pixma:get_capabilities()
   local capability_xml = Ivec.get_capability()

   local r ={
      {
         method = "POST",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
            ["Content-Type"] = "application/octet-stream",
         },
         data = capability_xml
      },
      {
         method = "GET",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
         },
      },
   }

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = Xml.parse(text)
   end
   return parsed, code
end

local function parse_ink(node)
   return {
      model = node:find_first("ivec:model")[1],
      color = node:find_first("ivec:color")[1],
      icon = node:find_first("ivec:icon")[1],
      level = node:find_first("ivec:level")[1],
      tca = node:find_first("vcn:tca")[1],
      order = node:find_first("ivec:order")[1]
   }
end

local function parse_msi(node)
   if not node then
      return nil
   end

   local msi = {}
   for _, v in ipairs(node) do
      msi[#msi+1] = { type = v.type, value = v[1] }
   end
   return msi
end

local function parse_jobinfo(node)
   if not node then
      return nil
   end

   local jobprogress_detail_node = node:find_first("ivec:jobprogress_detail")[1]
   local jobprogress_detail = {
      state = jobprogress_detail_node:find_first("ivec:state")[1],
      reason = jobprogress_detail_node:find_first("ivec:reason")[1]
   }

   return {
      jobprogress = node:find_first("ivec:jobprogress")[1],
      jobprogress_detail = jobprogress_detail,
      sheet_status = node:find_first("ivec:sheet_status")[1],
      complete_impression = node:find_first("ivec:complete_impression")[1],
      inputbin = node:find_first("ivec:inputbin")[1],
      inputbin_logical_name = node:find_first("ivec:inputbin_logical_name")[1],
      jobname = node:find_first("ivec:jobname")[1],
      username = node:find_first("ivec:username")[1],
      computername = node:find_first("ivec:computername")[1],
      job_description = node:find_first("ivec:job_description")[1],
      papersize = node:find_first("ivec:papersize")[1],
      papersize_custom_width = node:find_first("ivec:papersize_custom_width")[1],
      papersize_custom_height = node:find_first("ivec:papersize_custom_height")[1],
      papertype = node:find_first("ivec:papertype")[1],
      hostselected_papertype = node:find_first("ivec:hostselected_papertype")[1],
      impression_num = node:find_first("ivec:impression_num")[1],
   }
end

local function parse_status(text)
   local parsed = Xml.parse(text)
   local param_set = parsed:find_first("ivec:param_set")

   local input_bins = {}
   local i = 1
   while true do
      local bin = ("inputbin_p%d"):format(i)
      local currentpapertype = param_set:find("ivec:currentpapertype")[i]
      local currentpapersize = param_set:find("ivec:currentpapersize")[i]
      local current_papersize_width = param_set:find("ivec:current_papersize_width")[i]
      local current_papersize_height = param_set:find("ivec:current_papersize_height")[i]
      if not currentpapertype then
         break
      end
      input_bins[bin] = {
         currentpapertype = currentpapertype[1],
         currentpapersize = currentpapersize[1],
         current_papersize_width = current_papersize_width[1],
         current_papersize_height = current_papersize_height[1]
      }
      i = i + 1
   end

   local marker_info = {}
   local marker_info_node = param_set:find_first("ivec:marker_info")
   for _, node in ipairs(marker_info_node) do
      marker_info[#marker_info+1] = parse_ink(node)
   end

   return {
      response = param_set:find_first("ivec:response")[1],
      response_detail = param_set:find_first("ivec:response_detail")[1],
      status = param_set:find_first("ivec:status")[1],
      status_detail = param_set:find_first("ivec:status_detail")[1],
      current_support_code = param_set:find_first("ivec:current_support_code")[1],
      input_bins = input_bins,
      marker_info = marker_info,
      hri = param_set:find_first("vcn:hri")[1],
      pdr = param_set:find_first("vcn:pdr")[1],
      hrc = param_set:find_first("vcn:hrc")[1],
      isu = param_set:find_first("vcn:isu")[1],
      msi = parse_msi(param_set:find_first("vcn:msi")),
      jobinfo = parse_jobinfo(param_set:find_first("vcn:jobinfo"))
   }
end

function Pixma:get_status()
   local status_xml = Ivec.get_status()

   local r ={
      {
         method = "POST",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
            ["Content-Type"] = "application/octet-stream",
         },
         data = status_xml
      },
      {
         method = "GET",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
         },
      },
   }

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = parse_status(text)
   end
   return parsed, code
end

function Pixma:get_status_maintenance()
   local status_xml = Ivec.get_status("maintenance")

   local r ={
      {
         method = "POST",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
            ["Content-Type"] = "application/octet-stream",
         },
         data = status_xml
      },
      {
         method = "GET",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
         },
      },
   }

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = Xml.parse(text)
   end
   return parsed, code
end

function Pixma:start_job(file_data, format, job_id, opts)
   job_id = string.format("%08d", job_id)
   local dat = ""

   dat = dat .. Ivec.start_job(job_id)
   dat = dat .. Ivec.set_job_configuration(job_id)
   dat = dat .. Ivec.set_configuration(job_id, opts)
   dat = dat .. Ivec.send_data(job_id, format, file_data:len())
   dat = dat .. file_data
   dat = dat .. Ivec.end_job(job_id)

   -- Printers tend to have what is called "raw 9100" printing, where the all
   -- the data needed for printing something is blasted to the printer all at
   -- once over TCP port 9100. The actual data you send varies by manufacturer.
   -- In Canon's case, you send some XML configuration concatted with the image
   -- data. Then, you can use the separate HTTP interface on port 80 to check
   -- the progress of the print job.
   local c = assert(socket.connect(self.host, 9100))

   c:send(dat)
   c:close()
end

return Pixma
