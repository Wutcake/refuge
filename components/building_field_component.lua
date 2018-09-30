--[[
   Component for a field that grows crops
]]

local rng = _radiant.math.get_default_rng()
local Cube3 = _radiant.csg.Cube3
local Point2 = _radiant.csg.Point2
local Point3 = _radiant.csg.Point3
local log = radiant.log.create_logger('building_field')
local rng = _radiant.math.get_default_rng()

local BuildingFieldComponent = class()

local VERSIONS = {
   ZERO = 0,
   BFS_PLANTING = 1,
   DIRT_PLOT_RENDERING = 2,
   FIXUP_INCONSISTENT_FIELD_LAYERS = 3,
   ADD_FIELD_TO_CROPS = 4
}

local FALLOW_CROP_ID = 'fallow'

function BuildingFieldComponent:get_version()
   return VERSIONS.ADD_FIELD_TO_CROPS
end

function BuildingFieldComponent:initialize()
   -- Declare all the sv variables
   self._sv._soil_layer = nil
   self._sv._plantable_layer = nil
   self._sv._harvestable_layer = nil

   self._sv.size = nil -- Needs to remote to client for the farmer field renderer
   self._sv.contents = {} -- Needs to remote to the client for farmer field renderer

   self._sv.general_fertility = 0
   self._sv.current_crop_alias = nil -- remoted to client for the UI
   self._sv.current_crop_details = nil
   self._sv.has_set_crop = false -- remoted to client for the UI
   self._sv.num_crops = 0

   
   self._workers = {}  -- farmers currently working this field
end

function BuildingFieldComponent:create()
   -- Create the farm layers that will be used for bfs
   self._sv.size = Point2.zero -- This must be initialized to 0,0 so the renderer of this component can work

   -- Sigh, since entities can be destroyed in any order, these guys can go before us, and then we'd have a nil exception
   self._sv._soil_layer = self:_create_field_layer('stonehearth:farmer:field_layer:tillable')
   self._sv._plantable_layer = self:_create_field_layer('stonehearth:farmer:field_layer:plantable')
   self._sv._harvestable_layer = self:_create_field_layer('stonehearth:farmer:field_layer:harvestable')

   local min_fertility = stonehearth.constants.soil_fertility.MIN
   local max_fertility = stonehearth.constants.soil_fertility.MAX
   self._sv.general_fertility = rng:get_int(min_fertility, max_fertility)   --TODO; get from global service

   -- always start out fallow
   self._sv.current_crop_alias = FALLOW_CROP_ID
   self._sv.current_crop_details = stonehearth.farming:get_crop_details(FALLOW_CROP_ID)
   self._sv.has_set_crop = false
end

function BuildingFieldComponent:restore()
   self._location = radiant.entities.get_world_grid_location(self._entity)
   if self._needs_plantable_layer_placement then
      radiant.terrain.place_entity(self._sv._plantable_layer, self._location)
      self:_update_plantable_layer()
   end
   if self._needs_dirt_plot_upgrade then
      self:fixup_dirt_plots()
      self._needs_dirt_plot_upgrade = false
   end

   if self._needs_layer_validation then
      self:_validate_layers()
      self._needs_layer_validation = false
   end

   self._sv._soil_layer:get_component('destination')
                        :set_reserved(_radiant.sim.alloc_region3()) -- xxx: clear the existing one from cpp land!
                        :set_auto_update_adjacent(true)

   self._sv._harvestable_layer:get_component('destination')
                        :set_reserved(_radiant.sim.alloc_region3()) -- xxx: clear the existing one from cpp land!
                        :set_auto_update_adjacent(true)

   self._sv._plantable_layer:get_component('destination')
                        :set_reserved(_radiant.sim.alloc_region3()) -- xxx: clear the existing one from cpp land!
                        :set_auto_update_adjacent(true)
end

function BuildingFieldComponent:activate()
   self._location = radiant.entities.get_world_grid_location(self._entity)
   self._field_listeners = {}
   table.insert(self._field_listeners, radiant.events.listen(self._sv._soil_layer, 'radiant:entity:pre_destroy', self, self._on_field_layer_destroyed))
   table.insert(self._field_listeners, radiant.events.listen(self._sv._harvestable_layer, 'radiant:entity:pre_destroy', self, self._on_field_layer_destroyed))
   table.insert(self._field_listeners, radiant.events.listen(self._sv._plantable_layer, 'radiant:entity:pre_destroy', self, self._on_field_layer_destroyed))

   self._player_id_trace = self._entity:trace_player_id('farmer field component tracking player_id')
      :on_changed(function()
            stonehearth.ai:reconsider_entity(self._entity, 'farmer field player id changed')
            self:_update_score()
         end)

   self:_update_score()
end

function BuildingFieldComponent:_on_field_layer_destroyed(e)
   -- Something bad has happened! just destroy ourselves because we can't recover from a layer being destroyed
   if self._field_listeners then
      log:detail('A farmer field layer %s has been destroyed! destroying the entire field %s because there is no recovery. This is normal in autotests.', e.entity, self._entity)
      self:_on_destroy()
      radiant.entities.destroy_entity(self._entity)
   end
end

function BuildingFieldComponent:_create_field_layer(uri)
   local layer = radiant.entities.create_entity(uri, { owner = self._entity })
   layer:add_component('destination')
                              :set_region(_radiant.sim.alloc_region3())
                              :set_reserved(_radiant.sim.alloc_region3())
                              :set_auto_update_adjacent(true)

   layer:add_component('stonehearth:farmer_field_layer')
                                 :set_farmer_field(self)
   return layer
end

function BuildingFieldComponent:get_bounds()
   return self:_get_bounds()
end

function BuildingFieldComponent:_get_bounds()
   local size = self._sv.size
   local bounds = Cube3(Point3(0, 0, 0), Point3(size.x, 1, size.y))
   return bounds
end

function BuildingFieldComponent:on_field_created(town, size)
   -- Called from the farming service when the field is first created
   -- This will update the soil layer to say this entire field needs
   -- to be tilled.
   self._location = radiant.entities.get_world_grid_location(self._entity)
   self._sv.size = Point2(size.x, size.y)

   radiant.terrain.place_entity(self._sv._soil_layer, self._location)
   radiant.terrain.place_entity(self._sv._plantable_layer, self._location)
   radiant.terrain.place_entity(self._sv._harvestable_layer, self._location)

   for x=1, size.x do
      table.insert(self._sv.contents, {})
   end

   local soil_layer = self._sv._soil_layer
   local soil_layer_region = soil_layer:get_component('destination')
                                :get_region()

   -- Modify the soil layer to have the bounds of our cube
   soil_layer_region:modify(function(cursor)
      cursor:clear()
      cursor:add_cube(self:_get_bounds())
   end)

   town:register_farm(self._entity)

   self.__saved_variables:mark_changed()
end

-- Call from the client to set the crop on this farm to a new crop
function BuildingFieldComponent:set_crop(session, response, new_crop_id)
   self._sv.current_crop_alias = new_crop_id
   self._sv.current_crop_details = stonehearth.farming:get_crop_details(new_crop_id)
   self._sv.has_set_crop = true

   self:_update_plantable_layer()

   self.__saved_variables:mark_changed()
   return true
end

function BuildingFieldComponent:get_crop_details()
   return self._sv.current_crop_details
end

-- Called from the ai when a locatio nhas been tilled
function BuildingFieldComponent:notify_till_location_finished(location)
   local offset = location - radiant.entities.get_world_grid_location(self._entity)
   local x = offset.x + 1
   local y = offset.z + 1
   local is_furrow = false
   if x % 2 == 0 then
      is_furrow = true
   end
   local dirt_plot = {
      is_furrow = is_furrow,
      x = x,
      y = y
   }

   --self:_create_tilled_dirt(location, offset.x + 1, offset.z + 1)
   self._sv.contents[offset.x + 1][offset.z + 1] = dirt_plot
   local local_fertility = rng:get_gaussian(self._sv.general_fertility, stonehearth.constants.soil_fertility.VARIATION)
   --local dirt_plot_component = dirt_plot:get_component('stonehearth:dirt_plot')

   -- Have to update the soil model to make the plot visible.
   --dirt_plot_component:update_soil_model(local_fertility, 50)

   local soil_layer = self._sv._soil_layer
   local soil_layer_region = soil_layer:get_component('destination')
                                :get_region()

   soil_layer_region:modify(function(cursor)
      cursor:subtract_point(offset)
   end)

   -- Add the region to the plantable region if necessary
   self:_try_mark_for_plant(dirt_plot)

   self.__saved_variables:mark_changed()
end

-- Convert into build building at
function BuildingFieldComponent:plant_crop_at(x_offset, z_offset)
   local dirt_plot = self._sv.contents[x_offset][z_offset]
   radiant.assert(dirt_plot, "Trying to plant a crop on farm %s at (%s, %s) that has no dirt!", self._entity, x_offset, z_offset)
   local crop_type = self._sv.current_crop_alias

   if dirt_plot.contents ~= nil or not crop_type or self:_is_fallow() then
      return
   end

   local planted_entity = radiant.entities.create_entity(crop_type, { owner = self._entity })
   local position = Point3(self._location.x + x_offset - 1, self._location.y, self._location.z + z_offset - 1)
   radiant.terrain.place_entity_at_exact_location(planted_entity, position)
   dirt_plot.contents = planted_entity

   --If the planted entity is a crop, add a reference to the dirt it sits on.
   local crop_component = planted_entity:get_component('stonehearth:crop')
   crop_component:set_field(self, dirt_plot.x, dirt_plot.y)

   self._sv.num_crops = self._sv.num_crops + 1

   self:notify_score_changed()
   self.__saved_variables:mark_changed()

   return planted_entity
end

-- Repurpose to handle desconstruction of buildings?
function BuildingFieldComponent:notify_crop_destroyed(x, z)
   if self._sv.contents == nil then
      --Sigh the crop component hangs on to us instead of the entity
      --if this component is already destroyed, don't process the notification -yshan
      return
   end
   local dirt_plot = self._sv.contents[x][z]
   if dirt_plot then
      dirt_plot.contents = nil

      local harvestable_layer = self._sv._harvestable_layer
      local harvestable_layer_region = harvestable_layer:get_component('destination')
                                          :get_region()
      harvestable_layer_region:modify(function(cursor)
         cursor:subtract_point(Point3(x - 1, 0, z - 1))
      end)

      self._sv.num_crops = self._sv.num_crops - 1

      self:notify_score_changed()
      self.__saved_variables:mark_changed()
      self:_try_mark_for_plant(dirt_plot)
   end
end

--True if there are actively crops on this field, false otherwise
function BuildingFieldComponent:has_crops()
   return self._sv.num_crops > 0
end

--Repurpose to notify when building has been done?
function BuildingFieldComponent:notify_plant_location_finished(location)
   local x_offset = location.x - self._location.x + 1
   local z_offset = location.z - self._location.z + 1
   self:plant_crop_at(x_offset, z_offset)

   local p = Point3(x_offset - 1, 0, z_offset - 1)
   local plantable_layer = self._sv._plantable_layer
   local plantable_layer_region = plantable_layer:get_component('destination')
                                :get_region()

   plantable_layer_region:modify(function(cursor)
      cursor:subtract_point(p)
   end)
   self.__saved_variables:mark_changed()
end

-- repurpose to building at
function BuildingFieldComponent:crop_at(location)
   local x_offset = location.x - self._location.x + 1
   local z_offset = location.z - self._location.z + 1

   local dirt_plot = self._sv.contents[x_offset][z_offset]
   if dirt_plot then
      return dirt_plot.contents
   end
   return nil
end

-- repurpose to data at 
function BuildingFieldComponent:dirt_data_at(location)
   local x_offset = location.x - self._location.x + 1
   local z_offset = location.z - self._location.z + 1

   local dirt_plot = self._sv.contents[x_offset][z_offset]
   return dirt_plot
end

-- Mark all buildings in zone for destruction?
function BuildingFieldComponent:_on_destroy()
   --Unlisten on all the field plot things
   local contents = self._sv.contents

   self._sv.contents = nil

   for x=1, self._sv.size.x do
      for y=1, self._sv.size.y do
         local dirt_plot = contents[x][y]
         if dirt_plot then
            -- destroys the dirt and crop entities
            -- if you don't want them to disappear immediately, then we need to figure out how they get removed from the world
            -- i.e. render the plant as decayed and implement a work task to clear rubble
            -- remember to undo ghost mode if you keep the entities around (see stockpile_renderer:destroy)
            if dirt_plot.contents then
               radiant.entities.destroy_entity(dirt_plot.contents)
               dirt_plot.contents = nil
            end
            contents[x][y] = nil
         end
      end
   end

   --Unregister from the town
   local player_id = radiant.entities.get_player_id(self._entity)
   local town = stonehearth.town:get_town(player_id)
   town:unregister_farm(self._entity)


   self:_clear_field_listeners()

   radiant.entities.destroy_entity(self._sv._soil_layer)
   self._sv._soil_layer = nil

   radiant.entities.destroy_entity(self._sv._plantable_layer)
   self._sv._plantable_layer = nil

   radiant.entities.destroy_entity(self._sv._harvestable_layer)
   self._sv._harvestable_layer = nil

   if self._gameloop_listener then
      self._gameloop_listener:destroy()
      self._gameloop_listener = nil
   end
   if self._player_id_trace then
      self._player_id_trace:destroy()
      self._player_id_trace = nil
   end
end

--- On destroy, destroy all the dirt plots and the layers
function BuildingFieldComponent:destroy()
   if self._sv.contents ~= nil then
      self:_on_destroy()
   end
end

function BuildingFieldComponent:_clear_field_listeners()
   if self._field_listeners then
      for i, listener in ipairs(self._field_listeners) do
         listener:destroy()
      end
      self._field_listeners = nil
   end
end

-- Modify to finish all buildings
function BuildingFieldComponent:debug_grow_all_crops(grow_count)
   for x=1, self._sv.size.x do
      for y=1, self._sv.size.y do
         local dirt_plot = self._sv.contents[x][y]
         if not dirt_plot then
            local is_furrow = false
            if x % 2 == 0 then
               is_furrow = true
            end
            local dirt_plot = {
               is_furrow = is_furrow,
               x = x,
               y = y
            }
            self._sv.contents[x][y] = dirt_plot
            if not is_furrow and grow_count ~= nil then
               local crop = self:plant_crop_at(x, y)
               local growing_component = crop:get_component('stonehearth:growing')
               for i=1, grow_count do
                  growing_component:_grow()
               end
            end
         end
      end
   end
   self._sv._soil_layer:get_component('destination')
                        :set_region(_radiant.sim.alloc_region3())

   self._sv._plantable_layer:get_component('destination')
                        :set_region(_radiant.sim.alloc_region3())
end

-- Modify for versioning of build plots?
function BuildingFieldComponent:fixup_post_load(old_save_data)
   if old_save_data.version < VERSIONS.BFS_PLANTING then
      -- Declare all the sv variables
      self._sv._soil_layer = old_save_data.soil_layer
      self._sv._plantable_layer = self:_create_field_layer('stonehearth:farmer:field_layer:plantable')

      self._sv._harvestable_layer = old_save_data.harvestable_layer

      self._sv._location = old_save_data.location
      self._needs_plantable_layer_placement = true

      self._sv.current_crop_alias = old_save_data.crop_queue[1].uri
      self._sv.current_crop_details = old_save_data.crop_queue[1]

      self._sv.has_set_crop = true -- remoted to client for the UI
   end

   if old_save_data.version < VERSIONS.DIRT_PLOT_RENDERING then
      self._needs_dirt_plot_upgrade = true
   end

   if old_save_data.version < VERSIONS.FIXUP_INCONSISTENT_FIELD_LAYERS then
      self._needs_layer_validation = true
   end

   if old_save_data.version < VERSIONS.ADD_FIELD_TO_CROPS then
      for x, row in pairs(self._sv.contents) do
         for z, dirt_plot in pairs(row) do
            local crop = dirt_plot.contents
            if crop then
               crop:get_component('stonehearth:crop')
                        :set_field(self, x, z)
            end
            dirt_plot.removed_listener = nil
            dirt_plot.harvestable_listener = nil
            dirt_plot.listening_to_crop_events = nil
         end
      end
   end
end

function BuildingFieldComponent:fixup_dirt_plots()
   local old_contents = self._sv.contents
   for x=1, self._sv.size.x do
      for y=1, self._sv.size.y do
         local dirt_plot = old_contents[x][y]
         if dirt_plot then
            local dirt_plot_component = dirt_plot:get_component('stonehearth:dirt_plot')
            local crop = dirt_plot_component:get_contents()
            local new_dirt_plot = {
               is_furrow = dirt_plot_component:is_furrow(),
               x = x,
               y = y,
               contents = crop,
            }
            if crop then
               local crop_component = crop:get_component('stonehearth:crop')
               crop_component:set_field(self, x, y)
            end
            self._sv.contents[x][y] = new_dirt_plot
         end
      end
   end
end

function BuildingFieldComponent:_validate_layers()
   -- make sure all the harvest and planting layer stuff are consistent
   local contents = self._sv.contents
   local plantable_layer_region = self._sv._plantable_layer:get_component('destination')
                                :get_region()

   local harvestable_layer_region = self._sv._harvestable_layer:get_component('destination')
                                       :get_region()

   local soil_layer_region = self._sv._soil_layer:get_component('destination')
                                :get_region()

   for x=1, self._sv.size.x do
      for y=1, self._sv.size.y do
         local dirt_plot = contents[x][y]
         if dirt_plot then
            local p = Point3(x - 1, 0, y - 1)
            soil_layer_region:modify(function(cursor)
               cursor:subtract_point(p)
            end)

            if dirt_plot.contents then
               plantable_layer_region:modify(function(cursor)
                  cursor:subtract_point(p)
               end)
               local crop = dirt_plot.contents:get_component('stonehearth:crop')
            else
               harvestable_layer_region:modify(function(cursor)
                  cursor:subtract_point(p)
               end)
            end
         end
      end
   end
end

-- useful for making sure the harvest invariants are met.  expensive, though, so only
-- enable if you're debugging.
function BuildingFieldComponent:_check_harvest_invariants()
   local harvestable_dst = self._sv._harvestable_layer:get_component('destination')

   local harvest_rgn = harvestable_dst:get_region():get()
   local harvest_reserved = harvestable_dst:get_reserved():get()
   for x, row in ipairs(self._sv.contents) do
      for y, dirt_plot in ipairs(row) do
         local crop = dirt_plot.contents
         local location = Point3(x - 1, 0, y - 1)

         radiant.log.write('', 1, 'checking on %d,%d - %s - %s (%d - %d = %d)', x, y, tostring(crop), location,
            harvest_rgn:get_area(), harvest_reserved:get_area(), harvest_rgn:get_area() - harvest_reserved:get_area())

         if crop then
            local crop_comp = crop:get_component('stonehearth:crop')
            assert(crop_comp._sv._field, 'crop field has no field pointer!')

            if crop_comp:is_harvestable() then
               local crop_component = crop:get_component('stonehearth:crop')
               local cx, cy = crop_component:get_field_offset()
               assert(x == cx and y == cy, 'crop field offset disagrees with actual location')
               assert(harvest_rgn:contains(location), 'harvestable crop not in harvest region')
            else
               assert(not harvest_rgn:contains(location), 'non harvestable cropling in harvest region')
            end
         else
            assert(not harvest_rgn:contains(location), 'non crop in harvest region')
         end
      end
   end
end

function BuildingFieldComponent:add_worker(worker)
   self._workers[worker:get_id()] = true
   self:_reconsider_fields()
end

function BuildingFieldComponent:remove_worker(worker)
   self._workers[worker:get_id()] = nil
   self:_reconsider_fields()
end

function BuildingFieldComponent:_reconsider_fields()
   for _, layer in ipairs({self._sv._soil_layer, self._sv._plantable_layer, self._sv._harvestable_layer}) do
      stonehearth.ai:reconsider_entity(layer, 'worker count changed')
   end
end

function BuildingFieldComponent:get_worker_count(this_worker)
   local result = 0
   for worker in pairs(self._workers) do
      if worker ~= this_worker:get_id() then
         result = result + 1
      end
   end
   return result
end

return BuildingFieldComponent
