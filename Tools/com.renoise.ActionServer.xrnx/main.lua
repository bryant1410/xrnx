-------------------------------------------
-- Requires and initialization
-------------------------------------------

-- Hack: load GlobalMidiActions.lua from Libraries/..
local package_path = package.path
package.path  = package.path:gsub("[\\/]Libraries", "")

require "GlobalMidiActions"
package.path = package_path

-- local URL = require "ActionServer.URL"
local expand = require "expand"

require "log"

local log = Log(Log.ALL)

local root = "./"
local action_server = nil
local errors = {}


-------------------------------------------
--  Menu registration
-------------------------------------------

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:ActionServer:Start",
  active = function() 
    return not server_running()
  end,
  invoke = function()
    start_server()
  end
}
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:ActionServer:Stop",
  active = function() 
    return server_running()
  end,
  invoke = function()
    stop_server()
  end
}
renoise.tool():add_menu_entry {
  name = "--- Main Menu:Tools:ActionServer:Configure",
  invoke = function()
    configure_server()
  end
}


-------------------------------------------
--  Util functions
-------------------------------------------

class 'Util'

function Util:song()
  return renoise.song()
end

function Util:split_lines(str)
  local t = {}
  local function helper(line) table.insert(t, line) return "" end
  helper((str:gsub("(.-)\r?\n", helper)))
  return t
end

function Util:parse_message(m)
  local lines = Util:split_lines(m)
  local s = false
  local header = table.create()
  local body = ""
  header["Content-Length"] = 0
  local t = {}
  for k,v in ipairs(lines) do
     if v:match("^$") then s = true end
     if not s then
        t = Util:split(v,": ")
        if #t == 2 then
           header[t[1]] = t[2]
        else
           header[k] = v
        end
     else
        --body[k] = v
        body=body..v.."\r\n"
     end
  end
  return header, body
end

function Util:parse(url, default)
    -- initialize default parameters
    local parsed = {}
    for i,v in pairs(default or parsed) do parsed[i] = v end
    -- empty url is parsed to nil
    if not url or url == "" then return nil, "invalid url" end
    -- remove whitespace
    -- url = string.gsub(url, "%s", "")
    -- get fragment
    url = string.gsub(url, "#(.*)$", function(f)
        parsed.fragment = f
        return ""
    end)
    -- get scheme
    url = string.gsub(url, "^([%w][%w%+%-%.]*)%:",
        function(s) parsed.scheme = s; return "" end)
    -- get authority
    url = string.gsub(url, "^//([^/]*)", function(n)
        parsed.authority = n
        return ""
    end)
    -- get query stringing
    url = string.gsub(url, "%?(.*)", function(q)
        parsed.query = q
        return ""
    end)
    -- get params
    url = string.gsub(url, "%;(.*)", function(p)
        parsed.params = p
        return ""
    end)
    -- path is whatever was left
    if url ~= "" then parsed.path = url end
    local authority = parsed.authority
    if not authority then return parsed end
    authority = string.gsub(authority,"^([^@]*)@",
        function(u) parsed.userinfo = u; return "" end)
    authority = string.gsub(authority, ":([^:]*)$",
        function(p) parsed.port = p; return "" end)
    if authority ~= "" then parsed.host = authority end
    local userinfo = parsed.userinfo
    if not userinfo then return parsed end
    userinfo = string.gsub(userinfo, ":([^:]*)$",
        function(p) parsed.password = p; return "" end)
    parsed.user = userinfo
    return parsed
end

function Util:read_file(file_path, binary)
  local mode = "r"
  if binary then mode = "rb" end
  local file_ref,err = io.open(file_path, mode)
  if not err then
    local data=file_ref:read("*all")        
    io.close(file_ref)    
    return data
  else
    return nil,err;
  end
end

-- Compute the difference in seconds between local time and UTC.
function Util:get_timezone()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- Return a timezone string in ISO 8601:2000 standard form (+hhmm or -hhmm)
function Util:get_tzoffset()
  local h, m = math.modf(Util:get_timezone() / 3600)
  return string.format("%+.4d", 100 * h + 60 * m)
end

function Util:html_entity_decode(str)
  local a,b = str:gsub("%%20", " ")
   a,b = a:gsub("%+", " ")  
  a,b = a:gsub("%%5B", "[")
  a,b = a:gsub("%%5D", "]")
  return a
end

function Util:get_extension(file)
    return file:match("%.(%a+)$")
end

function Util:trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function Util:split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
   table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

-- Assumes "#comment" is a comment, "value  key_1 key_2"
function Util:parse_config_file(filename)
   local str = Util:read_file(root .. filename)
   local lines = Util:split_lines(str)
   local t = {}
   local k, v = nil
   for _,l in ipairs(lines) do
      if not l:find("^(%s*)#") then
        local a = Util:split(l, "%s+")
           for i=2,#a do
              t[a[i]] = a[1]
           end
      end
   end
   return t
end

-------------------------------------------
--  Renoise Actions Tree
-------------------------------------------

class 'ActionTree'

   ActionTree.message = {
       boolean_value = nil,
       int_value = nil,

       value_min_scaling = 0.0,
       value_max_scaling = 1.0,

       is_trigger = function() return true end,
       is_switch = function() return false end,
       is_rel_value = function() return false end,
       is_abs_value = function() return false end
   }   

   function ActionTree:find_action(action_name)
       if table.find(ActionTree.action_names, action_name) then
         log:info("Invoking: " .. action_name)
         invoke_action(action_name, ActionTree.message)
         return true
       else
         log:warn("Action not found: " .. action_name)
       end
       return false
     end

   function ActionTree:get_action_tree()
    ActionTree.action_names = available_actions()    
    local trees = table.create()
    
    local function add(t, v, is_last)        
        if is_last then
            table.insert(t,v)
            return
        elseif not t[v] then             
            t[v] = {}                           
        end        
        return t[v]
    end   
    
    local t,splits = {}
    local s = 0
    for _,name in ipairs(ActionTree.action_names) do
        splits = Util:split(name,":")        
        t = trees        
        s = #splits
        for l,v in ipairs(splits) do                          
             t = add(t, v, s-l==0)            
        end                
    end
    return trees    
   end

   -- Converts the complete tree or a subtree into a HTML list structure
   -- @param t       table representing the action tree or subtree
   -- @param depth   specifies the amount of nesting
   -- @return string containing a nested HTML list
   function ActionTree:to_html_list(t, depth)
       t = t or {}
       local list = "<ul>"
       for k,v in pairs(t) do
          if type(v) ~= "table" then
             list = list .. "<li><a href='#'>"..v.."</a></li>"
          else
            list = list .. "<li><a href='#'>" .. k .. "</a>"
            if depth and depth > 1 then
                list = list .. ActionTree:to_html_list(v, depth-1)
            end
            list = list .. "</li>"
          end
       end
       return list .. "</ul>"
   end

   -- Returns a portion of the tree
   -- Example: get_subtree("Transport", "Playback")
   -- @param ...  vararg representing the path to the subtree
   -- @return table containing the subtree
   function ActionTree:get_subtree(...)      
      local path = {...}       
      local t = ActionTree.action_tree      
      for _,v in ipairs(path) do
         t = t[v]
      end
      return t
   end

   ActionTree.action_tree = ActionTree:get_action_tree() 

-------------------------------------------
-- ActionServer
-------------------------------------------

class "ActionServer"

  ActionServer.document_root = root .. "html"

  function ActionServer:__init(address,port)
      -- create a server socket
      local server, socket_error =
        renoise.Socket.create_server(address, port)

      if socket_error then
        renoise.app():show_warning(
          "Failed to start the action server: " .. socket_error)
      else
        -- start running
        self.server = server
        self.server:run(self)
        log:info("Server running at " .. self:get_address())
      end
  end

  function ActionServer:socket_error(socket_error)
    renoise.app():show_warning(socket_error)
  end

  function ActionServer:get_address()
    return self.server.local_address .. ':' .. self.server.local_port
  end

  function ActionServer:get_date()
    return os.date("%a, %d %b %Y %X " .. Util:get_tzoffset())
  end

  function ActionServer:socket_accepted(socket)
    log:info("Socket accepted")
  end

   function ActionServer:get_action_names()
      return Action.action_names
   end 

  function ActionServer:parse_post_string(body)
    if #Util:trim(body) == 0 then return {} end
     local p = {}
     local key, val = nil
     for k,v in body:gmatch("([^=&]+)=([^=&]+)") do
       key = Util:html_entity_decode(Util:trim(k))
       val = Util:html_entity_decode(Util:trim(v))                    
       if key:match("%[%]$") then
         if p[key] == nil then
            p[key] = table.create()
         end
         p[key]:insert(val)
       else
         p[key] = val       
       end
     end     
     return p
  end

  function ActionServer:get_MIME(path)
    local ext = Util:get_extension(path)
    local mime = ActionServer.mime_types[ext] or "text/plain"
    log:info("Extension: " .. ext .. "; Content-Type: " .. mime)
  end

  function ActionServer:get_htdoc(path)
    if path == nil then path = "" end
    return ActionServer.document_root .. path
  end

  function ActionServer:is_htdoc(path)
    local fullpath = self:get_htdoc(path)
    local f,err = io.open(fullpath)
    if f then io.close(f) end
    local exists = (f~=nil)
    log:info("Path " .. fullpath .. " exists?: " .. tostring(exists))
    return exists
  end

  function ActionServer:is_expandable(path)
    local extensions = table.create{"lua","html"}
    local path_ext = Util:get_extension(path)
    return extensions:find(path_ext)
  end

  function ActionServer:set_header(k,v)
   self.header_map[k] = v
  end

  function ActionServer:init_header()
   self.header_map = table.create()
   self.header_map["Date"]  = self:get_date()
   self.header_map["Server"] = "Renoise Vx.xx"
   self.header_map["Cache-Control"] = "max-age=3600, must-revalidate"
   self.header_map["Accept-Ranges"] = "none"
  end

  function ActionServer:send_htdoc(socket, path, status, parameters)
     status = status or "200 OK"

     self:set_header("Content-Type", self:get_MIME(path))

     parameters = parameters or {}
     local fullpath = self:get_htdoc(path)
     --TODO if mime is of binary type, then binary = true
     local binary = false
     local template = Util:read_file(fullpath, binary)
     assert(template, "failed to read the teplate file")
     
     local page = nil

     if self:is_expandable(path) then
       self:set_header("Cache-Control", "private, max-age=0")
       page = expand(template, {L=self, renoise=renoise, P=parameters, Util=Util, ActionTree=ActionTree}, _G)
     else
       self:set_header("Cache-Control", "private, max-age=3600")
       page = template
     end
     
     local size =  #page; 
     local unit = "B"
     self:set_header("Content-Length", size)
     if size > 1024 then 
       unit = "KB"
       size = string.format("%.1f", size / 1024) 
     end 
     log:info(string.format("Content-Length: %s %s", size, unit))
    
     local header = "HTTP/1.1 " .. status .. "\r\n"
     for k,v in pairs(self.header_map) do
       header = string.format("%s%s: %s\r\n",header,k,v)
     end     
     header = header .. "\r\n"     
     socket:send(header)               
     local ok,err = socket:send(page)          
     if not ok then
       log:error("Failed to send data:\n".. err)
     end
  end

  ActionServer.chunked = false

  function ActionServer:socket_message(socket, message)
      self.remote_addr = socket.peer_address .. ":" .. socket.peer_port
      log:info("Remote Addr: " .. self.remote_addr)
      print("\r\n----------MESSAGE RECEIVED----------")

      local header, body = nil
      if self.chunked then
         header = self.header
         body = message
         self.chunked = false
      else
         header, body = Util:parse_message(message)
         self.header = nil
      end
      
      if #body < tonumber(header["Content-Length"]) then
        self.chunked = true
        self.header = header
        return
      end

      self:init_header()

      local parameters = nil -- POST and GET variables
      if #Util:trim(body) > 0 then log:info("Body:" .. body) end
      local path, url = nil
      local url_parts = {}
      local methods = table.create{"GET","POST","HEAD",
        "OPTIONS", "CONNECT", "PUT", "DELETE", "TRACE"}
      local method = header[1]:match("^(%w+)%s")

      if method ~= nil then        
        method = method:upper()
        url = header[1]:match("%s(.-)%s")        
        url_parts = Util:parse(url)                
        path = Util:trim(Util:html_entity_decode(url_parts.path))
      else
        log:warn("No HTTP method received")
        return
      end

      self.path = path

      if path == nil then
        log:warn("No HTTP path received")
        return
      end
      if #path == 0 then return end

      -- handle index pages quickly
      local index_pages = table.create{"/index.html","/index.lua","/"}
      if index_pages:find(path) then
          if path == "/" then path = index_pages[1] end          
            self:send_htdoc(socket, path)          
          return
      end

      if method ~= "HEAD" then
        parameters = self:parse_post_string(body)
        if  #path > 0 and self:is_htdoc(path) then
          if method == "POST" then
             -- parameters = self:parse_post_string(body)
          end
          self:send_htdoc(socket, path, nil, parameters)
          return
        else
          local action_name = string.sub(path:gsub('\/', ':'), 2)
          log:info ("Requested action:" .. action_name)
          local found = ActionTree:find_action(action_name)
          if found then            
             if parameters and parameters.ajax == "true" then               
               log:info("Action requested by Ajax")
               self:send_htdoc(socket, "/empty.txt")         
               return
             end
             self:set_header("Cache-Control", "private, max-age=0")
             self:send_htdoc(socket, index_pages[1], nil, parameters)          
             return
          end
        end
     end

    self:send_htdoc(socket, "/404.html", "404 Not Found", parameters)

    --- TODO: NON-HTTP (eg. Telnet, OSC)
--[[  if message == "p" then
        song().transport:start(1)
      elseif message == "s" then
        song().transport:stop()
      elseif #message > 0 then
        song().transport:start(1)
      end
]]--

  end
  
   function ActionServer:stop()
     if self.server then
       self.server:stop()
       self.server = nil
     end
   end

-------------------------------------------
local address = "localhost"
local port = 80
local INADDR_ANY = false

function restore_default_configuration()
    port = 80
    address = "0.0.0.0"
    INADDR_ANY = false
end

function server_running()
    return (action_server ~= nil)
end

function start_server()
    print("\r\n==========STARTING SERVER===========")
    assert(not action_server, "server is already running")

    ActionServer.mime_types = Util:parse_config_file("/mime.types")
    action_server = ActionServer(address, port)
end

function stop_server()
   print("\r\n==========STOPPING SERVER===========")
   assert(action_server, "server is not running")

   action_server:stop()
   action_server = nil
end

-- todo hostnames
local function is_valid_ip(str)
   return str:match("^%d.%d.%d.%d$") or str == "localhost"
end

local function set_address(value)
   if is_valid_ip(value) then
      address = value
   end
end

local function set_port(value)
   port = value
end

function configure_server()
   local vb = renoise.ViewBuilder()
   local DEFAULT_DIALOG_MARGIN =
    renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
   local DEFAULT_CONTROL_SPACING =
    renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
   local TEXT_ROW_WIDTH = 80
   local temp = address

   local content =
     vb:column {
       style = "invisible",
       margin = DEFAULT_DIALOG_MARGIN,
       spacing = DEFAULT_CONTROL_SPACING,

       vb:row {
          vb:text {
            width = TEXT_ROW_WIDTH,
            text = "INADDR_ANY"
          },
          vb:checkbox {
            value = INADDR_ANY,
            notifier = function(value)
               INADDR_ANY = value
               if value then
                 vb.views.address_field.value = "0.0.0.0"
               else
                 vb.views.address_field.value = temp
               end
            end
          },
        },

       vb:row {
          vb:text {
            width = TEXT_ROW_WIDTH,
            text = "Address"
          },
          vb:textfield {
            visible = not INADDR_ANY,
            id = "address_field",
            value = address,
            notifier = function(value)
              set_address(value)
            end
          },
        },

        vb:row {
          vb:text {
            width = TEXT_ROW_WIDTH,
            text = "Port"
          },
          vb:valuebox {
            value = port,
            min = 0,
            max = 65535,
            notifier = function(value)
              set_port(value)
            end
          }
        }

     }

  local buttons = {"OK", "Default"}

  local choice = renoise.app():show_custom_prompt(
    "Configure ActionServer", content, buttons)
  
  if (choice == "Cancel") then
    -- restore_previous_configuration()
  elseif (choice == "Default") then
      restore_default_configuration()
  end

  if choice then
   if server_running() then 
     stop_server()
   end
   start_server()
  end
end