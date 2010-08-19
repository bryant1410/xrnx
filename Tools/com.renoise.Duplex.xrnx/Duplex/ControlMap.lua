--[[----------------------------------------------------------------------------
-- Duplex.ControlMap
----------------------------------------------------------------------------]]--

--[[

Requires: Globals

About:

  Essentially, the ControlMap class will import a control-map file, and add 
  some extra methods, more handy methods for accessing the groups. 

Notes on the XML syntax:

  - Supported elements are: <Row>, <Column>, <Group> and <Param>
  
  - <Group> nodes cannot be nested 
  
  - Only <Param> nodes are supported inside a <Group> node
  
  - Use <Row> and <Column> nodes for controlling the layout 
    - Use "orientation" attribute to control vertical/horizontal layout 
  
  - Indicate grid layout by supplying a "column" attribute for a <Group> node
    - Note that orientation is then ignored (using a grid layout)
  
  - Use "size" attribute to control the unit size of certain controls like 
    sliders
  
  - Underscore is not allowed in attribute names

--]]


--==============================================================================

class 'ControlMap' 

function ControlMap:__init()
  TRACE("ControlMap:__init")

  -- groups by name, e.g. self.groups["Triggers"]
  self.groups = table.create() 

  -- remember the name (this is a 'read-only' property, 
  -- setting it will not do anything useful)
  self.file_path = ""

  -- internal stuff
  
  -- unique id, reset each time a control-map is parsed
  self.id = nil 
  -- control-map parsed into table
  self.definition = nil 
end


--------------------------------------------------------------------------------

-- load_definition: load and parse xml
-- @param file_path (string) the name of the file, e.g. "my_map.xml"

function ControlMap:load_definition(file_path)
  
  self.file_path = file_path
  
  -- try to find the controller definition in the package path
  local package_paths = {}
  package.path:gsub("([^;]*)", function(str) 
    if (#str > 1) then table.insert(package_paths, str) end
  end)
  
  for _,path in pairs(package_paths) do
    local lib_path_base = path:gsub("?.lua", "")
 
    if io.exists(lib_path_base .. "/Duplex/" .. file_path) then
      file_path = lib_path_base .. "/Duplex/" .. file_path
      break
    end
    
    if (io.exists(lib_path_base .. file_path)) then
      file_path = lib_path_base .. file_path
      break
    end
  end
       
  -- load the control-map
  if io.exists(file_path) then
    TRACE("ControlMap:load_definition:", file_path)
    
    local xml_string = self.read_file(self, file_path)
    self:parse_definition(file_path, xml_string)
  
  else
    renoise.app():show_error(
      ("Failed to load controller definition file: '%s'. " ..
       "The controller is not available."):format(file_path))
  end
end


--------------------------------------------------------------------------------

-- parse the supplied xml string (reset the counter first)

function ControlMap:parse_definition(control_map_name, xml_string)
  self.id = 0

  -- must guard any file io access. may fail, and we don't want to bother
  -- the user with cryptic LUA error messages then...
  local succeeded, result = pcall(function() 
    -- remove comments before parsing
    xml_string = string.gsub (xml_string, "(<!--.-->)", "")
    return self:parse_xml(xml_string) 
  end)
  
  if (succeeded) then
    self.definition = result
  
  else
    print("Notice! ControlMap:parse_definition FAILED:", result)
    
    renoise.app():show_error(
      ("Whoops! Failed to parse the controller definition file: "..
       "'%s'.\n\n%s"):format(control_map_name, result or "unknown error"))       
  end
end


--------------------------------------------------------------------------------

-- retrieve <param> by position within group
-- @return the <param> attributes array

function ControlMap:get_indexed_element(index,group_name)
  if (self.groups[group_name] and self.groups[group_name][index]) then
    return self.groups[group_name][index].xarg
  end

  return nil
end

--------------------------------------------------------------------------------

function ControlMap:get_group_size(group_name)

  return #self.groups[group_name]

end

--------------------------------------------------------------------------------

-- get_element_by_value() 
-- this retrieves a parameter by note/cc-value-string
-- @param str (string) note/cc-value, e.g. "CC#10"
-- @return table

function ControlMap:get_param_by_value(str)
  TRACE("ControlMap:get_param_by_value",str)

  for _,group in pairs(self.groups) do
    for k,v in ipairs(group) do
      if (v["xarg"]["value"] == str) then
        return v
      end
    end
  end

  return nil
end


--------------------------------------------------------------------------------

-- get_param_by_action() - used for parsing OSC messages
-- retrieve a parameter by matching it's value or action attribute, 
-- with wildcard support for particular types of value:
-- "/press 1 %i" matches "/press 1 1" but not "/press 1 A". 
--
-- use the action property if it's available, otherwise use
-- the "value" property - the action property is needed when
-- a device transmit a different outgoing than incoming value 
-- 
-- @param str (string) message to match against
-- @return  <Param> node as table (only the first match is returned),
--          and the value (if matched against a wildcard)

function ControlMap:get_param_by_action(str)
  TRACE("ControlMap:get_param_by_action",str)

  -- todo: attempt a literal match (faster)
  --[[
  for _,group in pairs(self.groups) do
    for k,v in ipairs(group) do
      local str_prop = v["xarg"]["action"] or v["xarg"]["value"]
      if (str_prop == str) then
        return v
      end
    end
  end
  ]]
  -- check with wildcard support:
  local str_table = table.create()
  for v in string.gmatch(str,"[^%s]+") do
    str_table:insert(v)
  end

  for _,group in pairs(self.groups) do
    for _,v in ipairs(group) do
      local str_prop = v["xarg"]["action"] or v["xarg"]["value"]
      if (str_prop) then

        -- split match into parts, separated by whitespace
        local prop_table = table.create()
        for p in string.gmatch(str_prop,"[^%s]+") do
          prop_table:insert(p)
        end
        if (#str_table~=#prop_table) then
          -- ignore if different number of parts

        elseif(str_table[1]~=prop_table[1]) then
          -- ignore if different pattern 

        else
          -- return matching group + extracted value
          local ignore = false
          for o=2,#prop_table do
            if (not ignore) then
              if (prop_table[o]=="%f") then
                return v,tonumber(str_table[o])
              elseif (prop_table[o]=="%i") then
                return v,tonumber(str_table[o])
              --elseif (prop_table[o]=="(%s)") then
                --return v,tostring(str_table[o])
              elseif (prop_table[o]~=str_table[o]) then
                -- wrong argument, ignore
                ignore = true
              end
            end
          end
        end
      end
    end
  end

end


--------------------------------------------------------------------------------

-- return number of columns for the provided group

function ControlMap:count_columns(group_name)
  TRACE("ControlMap:count_columns",group_name)

  local group = self.groups[group_name]
  if (group) then
    local row, column, columns = 1, 1, nil
    self.__width = #group
    if (group["columns"]) then
      return group["columns"]
    end
  end

end

--------------------------------------------------------------------------------

function ControlMap:read_file(file_path)
  local file_ref, err = io.open(file_path, "r")
  
  if (not err) then
    local rslt = file_ref:read("*a")
    io.close(file_ref)
    return rslt
  else
    return nil,err
  end

end


--------------------------------------------------------------------------------

-- Determine the type of message (OSC/Note/CC)
-- @return integer (e.g. MIDI_NOTE_MESSAGE)

function ControlMap:determine_type(str)
  
  -- url
  if string.sub(str,0,1)=="/" then
    return OSC_MESSAGE
  
  -- cc, if first two characters match "CC"
  elseif string.sub(str,1,2)=="CC" then
    return MIDI_CC_MESSAGE

  -- note, if message has a "#" or "-" as the second character
  elseif string.sub(str,2,2)=="#" or string.sub(str,2,2)=="-" then
    return MIDI_NOTE_MESSAGE

  -- pitch bend, if it matches the pich-bend name
  elseif string.sub(str,1,2)=="PB" then
    return MIDI_PITCH_BEND_MESSAGE
  end
  
end


--------------------------------------------------------------------------------

-- Parse the control-map, and add runtime
-- information (element id's and group names)

function ControlMap:parse_xml(s)
  TRACE('ControlMap:parse_xml(...)')

  local stack = {}
  local top = {}
  table.insert(stack, top)

  local i, j = 1, 1
  local parameter_index = 1
  
  local function parseargs(s)
    local arg = {}
    string.gsub(s, "(%w+)=([\"'])(.-)%2", function (w, _, a)
      arg[w] = a
    end)

    -- meta-attr: add unique id for every node
    arg.id = string.format("%d", self.id)
    self.id = self.id+1

    return arg
  end
  
  while true do
    local ni,j,c,label,xarg, empty = string.find(
      s, "<(%/?)([%w:]+)(.-)(%/?)>", i)

    if (not ni) then 
      break 
    end
    
    local text = string.sub(s, i, ni - 1)
    
    if (not string.find(text, "^%s*$")) then
      table.insert(top, text)
    end
    
    if (empty == "/") then  -- empty element tag
      local xargs=parseargs(xarg)

      -- meta-attr: index each <Param> node
      if (label == "Param") then
        xargs.index = parameter_index
        parameter_index = parameter_index + 1
      end

      -- meta-attr: add size attribute to (toggle)buttons, if not defined
      --if (not)xargs["size"]
      if (xargs["type"]) and
        (xargs["type"]=="button") or
        (xargs["type"]=="togglebutton") then
        if (not xargs["size"]) then
          xargs["size"] = 1
        end
      end

      table.insert(top, {label=label, xarg=xargs, empty=1})
    
    elseif (c == "") then   -- start tag
      top = {label=label, xarg=parseargs(xarg)}
      table.insert(stack, top)   -- new level
    
    else  -- end tag
      local toclose = table.remove(stack) -- remove top
      top = stack[#stack]
      
      if (#stack < 1) then
        error("nothing to close with "..label)
      end
      
      if toclose.label ~= label then
        error("trying to close "..toclose.label.." with "..label)
      end
      
      table.insert(top, toclose)

      -- meta-attr : columns and rows
      if (label == "Group") then
        
        -- add "columns" attribute to *all* groups
        local columns = nil
        
        if (not toclose.xarg.columns) then
          if (toclose.xarg.orientation and 
              toclose.xarg.orientation == "vertical") 
          then
            columns = 1
          else
            columns = #toclose
          end

        else 
          columns = tonumber(toclose.xarg.columns)
        end
        
        toclose.columns = columns
        
        local counter = 0
        
        for key,val in ipairs(toclose) do
          
          -- add "group_name" to all members
          toclose[key].xarg.group_name =  toclose.xarg.name
          
          -- figure out active row/column
          toclose[key].xarg.column = counter + 1
          toclose[key].xarg.row = math.floor(
            ((toclose[key].xarg.index - 1) / columns) + 1)
          
          counter = counter + 1
          if (counter >= columns) then
            counter = 0
          end
        end
        
        self.groups[toclose.xarg.name] = toclose
      end

      -- reset parameter_index
      parameter_index = 1

    end
    i = j + 1
  end
  
  local text = string.sub(s, i)
  
  if (not string.find(text, "^%s*$")) then
    table.insert(stack[#stack], text)
  end
  
  if (#stack > 1) then
    error("unclosed "..stack[stack.n].label)
  end
  
  return stack[1]
end

