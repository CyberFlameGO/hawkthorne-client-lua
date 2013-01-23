local Gamestate = require 'vendor/gamestate'
local queue = require 'queue'
local anim8 = require 'vendor/anim8'
local tmx = require 'vendor/tmx'
local HC = require 'vendor/hardoncollider'
local Timer = require 'vendor/timer'
local Tween = require 'vendor/tween'
local camera = require 'camera'
local window = require 'window'
local sound = require 'vendor/TEsound'
local controls = require 'controls'
local transition = require 'transition'
local HUD = require 'hud'
local music = {}
require 'vendor/lube'

local node_cache = {}
local tile_cache = {}

local Player = require 'player'
local Floor = require 'nodes/floor'
local Floorspace = require 'nodes/floorspace'
local Floorspaces = require 'floorspaces'
local Platform = require 'nodes/platform'
local Wall = require 'nodes/wall'

local ach = (require 'achievements').new()
local Client = require 'client'

local function limit( x, min, max )
    return math.min(math.max(x,min),max)
end

local function load_tileset(name)
    if tile_cache[name] then
        return tile_cache[name]
    end
    
    local tileset = tmx.load(require("maps/" .. name))
    tile_cache[name] = tileset
    return tileset
end

function load_node(name)
    if node_cache[name] then
        return node_cache[name]
    end

    local node = require('nodes/' .. name)
    node_cache[name] = node
    return node
end

local function on_collision(dt, shape_a, shape_b, mtv_x, mtv_y)
    local player, node, node_a, node_b

    if shape_a.player then
        player = shape_a.player
        node = shape_b.node
    elseif shape_b.player then
        player = shape_b.player
        node = shape_a.node
    else
        node_a = shape_a.node
        node_b = shape_b.node
    end

    if node then
        node.player_touched = true

        if node.collide then
            node:collide(player, dt, mtv_x, mtv_y)
        end
    elseif node_a then
        if node_a.collide then
            node_a:collide(node_b, dt, mtv_x, mtv_y)
        end
        if node_b.collide then
            node_b:collide(node_a, dt, mtv_x, mtv_y)
        end
    end

end

-- this is called when two shapes stop colliding
local function collision_stop(dt, shape_a, shape_b)
    local player, node

    if shape_a.player then
        player = shape_a.player
        node = shape_b.node
    elseif shape_b.player then
        player = shape_b.player
        node = shape_a.node
    else
        node_a = shape_a.node
        node_b = shape_b.node
    end

    if node then
        node.player_touched = false

        if node.collide_end then
            node:collide_end(player, dt)
        end
    else
        if node_a.collide_end then
            node_a:collide_end(node_b, dt)
        end
        if node_b.collide_end then
            node_b:collide_end(node_a, dt)
        end
    end
end

local function setBackgroundColor(map)
    local prop = map.properties
    if not prop.red then
        love.graphics.setBackgroundColor(0, 0, 0)
        return
    end
    love.graphics.setBackgroundColor(tonumber(prop.red),
                                     tonumber(prop.green),
                                     tonumber(prop.blue))
end

local function getCameraOffset(map)
    local prop = map.properties
    if not prop.offset then
        return 0
    end
    return tonumber(prop.offset) * map.tilewidth
end

local function getTitle(map)
    local prop = map.properties
    return prop.title or "UNKNOWN"
end

local function getSoundtrack(map)
    local prop = map.properties
    return prop.soundtrack or "level"
end

local Level = {}
Level.__index = Level
Level.level = true

function Level.new(name)
    local level = {}
    setmetatable(level, Level)

    level.over = false
    level.state = 'idle'  -- TODO: Use state machine
    level.name = name
    level.client = Client.getSingleton()

    assert( love.filesystem.exists( "maps/" .. name .. ".lua" ),
            "maps/" .. name .. ".lua not found.\n\n" ..
            "Have you generated your maps lately?\n\n" ..
            "LINUX / OSX: run 'make maps'\n" ..
            "WINDOWS: use tmx2lua to generate\n\n" ..
            "Check the documentation for more info."
    )

    level.map = require("maps/" .. name)
    level.background = load_tileset(name)
    level.collider = HC(100, on_collision, collision_stop)
    level.offset = getCameraOffset(level.map)
    level.music = getSoundtrack(level.map)
    level.spawn = 'studyroom'
    level.title = getTitle(level.map)
 
    level:panInit()

    level.players = {}
    level.boundary = {
        width =level.map.width  * level.map.tilewidth,
        height=level.map.height * level.map.tileheight
    }

    level.transition = transition.new('fade', 0.5)
    level.events = queue.new()
    level.nodes = {}
    level.doors = {}

    level.default_position = {x=0, y=0}
    for k,v in pairs(level.map.objectgroups.nodes.objects) do
        node = load_node(v.type)
        if node then
            v.objectlayer = 'nodes'
            table.insert( level.nodes, node.new( v, level.collider ) )
        end
        if v.type == 'door' then
            if v.name then
                if v.name == 'main' then
                    level.default_position = {x=v.x, y=v.y}
                end
                level.doors[v.name] = {x=v.x, y=v.y, node=level.nodes[#level.nodes]}
            end
        end
    end

    if level.map.objectgroups.floor then
        for k,v in pairs(level.map.objectgroups.floor.objects) do
            v.objectlayer = 'floor'
            Floor.new(v, level.collider)
        end
    end

    if level.map.objectgroups.floorspace then
        level.floorspace = true
        for k,v in pairs(level.map.objectgroups.floorspace.objects) do
            v.objectlayer = 'floorspace'
            table.insert(level.nodes, Floorspace.new(v, level))
        end
    end

    if level.map.objectgroups.platform then
        for k,v in pairs(level.map.objectgroups.platform.objects) do
            v.objectlayer = 'platform'
            table.insert(level.nodes, Platform.new(v, level.collider))
        end
    end

    if level.map.objectgroups.wall then
        for k,v in pairs(level.map.objectgroups.wall.objects) do
            Wall.new(v, level.collider)
        end
    end

    level:restartLevel()
    return level
end

function Level:restartLevel()
    self.over = false

    self.player = Player.factory(self.collider)
    self.player:refreshPlayer(self.collider)
    self.player.boundary = {
        width = self.map.width * self.map.tilewidth,
        height = self.map.height * self.map.tileheight
    }
    
    self.player.position = {x = self.default_position.x,
                            y = self.default_position.y}
    Floorspaces:init()
end


function Level:enter( previous, door )
    self.respawn = false
    self.state = 'idle'

    self.transition:forward(function()
        self.state = 'active'
    end)

    ach:achieve('enter ' .. self.name)
    self.client.level = self.name

    local dg = string.format("%s %s %s", self.client.entity, 'enter', self.name)
    self.client.udp:send(dg)

    --only restart if it's an ordinary level
    if previous.level or previous==Gamestate.get('overworld') then
        self.previous = previous
        self:restartLevel()
    end
    if previous == Gamestate.get('overworld') then
        self.respawn = true
        self.player.character:respawn()
    end
    if not self.player then
        self:restartLevel()
    end

    self.player:setSpriteStates('default')

    camera.max.x = self.map.width * self.map.tilewidth - window.width

    setBackgroundColor(self.map)
 
    sound.playMusic( self.music )

    self.hud = HUD.new(self)

    if door then
        self.player.position = {
            x = self.doors[ door ].x + self.doors[ door ].node.width / 2 - self.player.width / 2,
            y = self.doors[ door ].y + self.doors[ door ].node.height - self.player.height
        }
        if self.doors[ door ].warpin then
            self.player:respawn()
        end
        if self.doors[ door ].node then
            self.doors[ door ].node:show()
            self.player.freeze = false
        end
    end

    self:moveCamera()

    for i,node in ipairs(self.nodes) do
        if node.enter then node:enter(previous) end
    end
end

function Level:init()
end

local function leaveLevel(level, levelName, doorName)
  local destination = Gamestate.get(levelName)
            
  if level == destination then
    level.player.position = { -- Copy, or player position corrupts entrance data
      x = level.doors[doorName].x + level.doors[doorName].node.width / 2 - level.player.width / 2,
      y = level.doors[doorName].y + level.doors[doorName].node.height - level.player.height
    }
    return
  end

  Gamestate.switch(levelName, doorName)
end

function Level:update(dt)
    --assert(self.client.level == "town","town expected. found:"..self.client.level)
    --self:updatePan(dt)
    self.client:update(dt)
    local player = self.client.players[self.client.entity]
    if not player then return end
    local playerWidth = 48
    local x = player.x + playerWidth / 2
    local y = player.y - self.map.tilewidth * 4.5

    self:updatePan(dt)
    self:moveCamera()

    Timer.update(dt)

end

function Level:moveCamera()
    local player = self.client.players[self.client.entity]
    if not player then return end
    local playerWidth = 48
    local x = player.x + playerWidth / 2
    local y = player.y - self.map.tilewidth * 4.5
    camera:setPosition( math.max(x - window.width / 2, 0),
                        limit( limit(y, 0, self.offset) + self.pan, 0, self.offset ) )

end

function Level:quit()
    if self.respawn ~= nil then
        Timer.cancel(self.respawn)
    end
end

function Level:leave()
  self.state = 'idle'
end

function Level:exit(levelName, doorName)
  self.respawn = false
  if self.state ~= 'idle' then
    self.state = 'idle'
    self.transition:backward(function()
      self.events:push('exit', levelName, doorName)
    end)
  end
end


function Level:draw()

    print(self.client.level)
    
    self.background:draw(0, 0)
    self.client:draw()
    --TODO:draw inventory, hud and achievements
    --self.player.inventory:draw(self.player.position)
    --self.hud:draw( self.player )
    --ach:draw()

--    if self.state == 'idle' then
--      self.transition:draw(camera.x, camera.y, camera:getWidth(), camera:getHeight())
--    end
--
end

-- draws the nodes based on their location in the y axis
-- this is an accurate representation of the location
-- written by NimbusBP1729, refactored by jhoff
function Level:floorspaceNodeDraw()
    local layers = {}
    local player = self.player
    local fp = player.footprint
    local fp_base = math.floor( fp.y + fp.height )
    local player_drawn = false
    local player_center = player.position.x + player.width / 2

    --iterate through the nodes and place them in layers by their lowest y value
    for _,node in pairs(self.nodes) do
        if node.draw then
            local node_position = node.position and node.position or ( ( node.x and node.y ) and {x=node.x,y=node.y} or ( node.node and {x=node.node.x,y=node.node.y} or false ) )
            assert( node_position, 'Error! Node has to have a position!' )
            assert( node.height and node.width, 'Error! Node must have a height and a width property!' )
            local node_center = node_position.x + ( node.width / 2 )
            local node_depth = ( node.node and node.node.properties and node.node.properties.depth ) and node.node.properties.depth or 0
            local node_direction = ( node.node and node.node.properties and node.node.properties.direction ) and node.node.properties.direction or false
            -- base is, by default, offset by the depth
            local node_base = node_position.y + node.height - node_depth
            -- adjust the base by the players position
            -- if on floor and not behind or in front
            if fp.offset == 0 and node_direction and node_base < fp_base and node_position.y + node.height > fp_base then
                node_base = fp_base - 3
                if ( node_direction == 'left' and player_center < node_center ) or
                   ( node_direction == 'right' and player_center > node_center ) then
                    node_base = fp_base + 3
                end
            end
            -- add the node to the layer
            node_base = math.floor( node_base )
            while #layers < node_base do table.insert( layers, false ) end
            if not layers[ node_base ] then layers[ node_base ] = {} end
            table.insert( layers[ node_base ], node )
         end
    end

    --draw the layers
    for y,nodes in pairs(layers) do
        if nodes then
            for _,node in pairs(nodes) do
                --draw player once his neighbors are found
                if not player_drawn and fp_base <= y then
                    self.player:draw()
                    player_drawn = true
                end
                node:draw()
            end
        end
    end
    if not player_drawn then
        self.player:draw()
    end
end

function Level:leave()
    ach:achieve('leave ' .. self.name)
    for i,node in ipairs(self.nodes) do
        if node.leave then node:leave() end
        if node.collide_end then
            node:collide_end(self.player)
        end
    end
end

function Level:keyreleased( button )
    local dg = string.format("%s %s %s", self.client.entity, 'keyreleased', button)
    self.client.udp:send(dg)
end

function Level:keypressed( button , player)
    local dg = string.format("%s %s %s", self.client.entity, 'keypressed', button)
    self.client.udp:send(dg)
end

function Level:panInit()
    self.pan = 0
    self.pan_delay = 1
    self.pan_distance = 80
    self.pan_speed = 140
    self.pan_hold_up = 0
    self.pan_hold_down = 0
end

function Level:updatePan(dt)
    local up = controls.isDown( 'UP' ) and not self.player.controlState:is('ignoreMovement')
    local down = controls.isDown( 'DOWN' ) and not self.player.controlState:is('ignoreMovement')

    if up and self.player.velocity.x == 0 then
        self.pan_hold_up = self.pan_hold_up + dt
    else
        self.pan_hold_up = 0
    end
    
    if down and self.player.velocity.x == 0 then
        self.pan_hold_down = self.pan_hold_down + dt
    else
        self.pan_hold_down = 0
    end

    if up and self.pan_hold_up >= self.pan_delay then
        self.player.gaze_state = 'gaze'
        self.pan = math.max( self.pan - dt * self.pan_speed, -self.pan_distance )
    elseif down and self.pan_hold_down >= self.pan_delay then
        --we currently have no sprite for looking down
        --self.player.crouch_state = 'gaze'
        self.pan = math.min( self.pan + dt * self.pan_speed, self.pan_distance )
    else
        self.player.gaze_state = self.player:getSpriteStates()[self.player.current_state_set].gaze_state
        if self.pan > 0 then
            self.pan = math.max( self.pan - dt * self.pan_speed, 0 )
        elseif self.pan < 0 then
            self.pan = math.min( self.pan + dt * self.pan_speed, 0 )
        end
    end
end

return Level
