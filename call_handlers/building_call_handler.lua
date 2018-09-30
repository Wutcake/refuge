local Color4 = _radiant.csg.Color4

local building_service = stonehearth.building
local validator = radiant.validator

local BuildingCallHandler = class()


function StockpileCallHandler:set_stockpile_filter(session, response, storage_entity, filter)
   if radiant.entities.is_entity(storage_entity) then
      validator.expect_argument_types({validator.optional('table')}, filter)
      validator.expect.matching_player_id(session.player_id, storage_entity)
      local storage_component = storage_entity:get_component('stonehearth:storage')
      assert(storage_component)
      storage_component:set_filter(filter)
   end
   return true
end

return StockpileCallHandler


-- runs on the client!!
function BuildingCallHandler:choose_new_field_location(session, response)
   stonehearth.selection:select_designation_region(stonehearth.constants.xz_region_reasons.NEW_FIELD)
      :set_max_size(11)
      :use_designation_marquee(Color4(255, 255, 255, 255))
      :set_cursor('stonehearth:cursors:zone_farm')
      :set_find_support_filter(stonehearth.selection.valid_terrain_blocks_only_xz_region_support_filter({
            grass = true,
            dirt = true
         }))

      :done(function(selector, box)
            local size = {
               x = box.max.x - box.min.x,
               y = box.max.z - box.min.z,
            }
            _radiant.call('stonehearth:create_new_field', box.min, size)
                     :done(function(r)
                           response:resolve({ field = r.field })
                        end)
                     :always(function()
                           selector:destroy()
                        end)
         end)
      :fail(function(selector)
            selector:destroy()
            response:reject('no region')
         end)
      :go()
end

-- runs on the server!
function BuildingCallHandler:create_new_field(session, response, location, size)
   validator.expect_argument_types({'Point3', 'table'}, location, size)
   validator.expect.num.range(size.x, 1, 11)
   validator.expect.num.range(size.y, 1, 11)

   local entity = stonehearth.farming:create_new_field(session, location, size)
   return { field = entity }
end

--TODO: Send an array of soil_plots and the type of the crop for batch planting
function BuildingCallHandler:plant_crop(session, response, soil_plot, crop_type, player_specified, auto_plant, auto_harvest)
   validator.expect_argument_types({validator.any_type(), 'string', 'boolean', 'boolean', 'boolean'}, soil_plot, crop_type, player_specified, auto_plant, auto_harvest)
   --TODO: remove this when we actually get the correct data from the UI
   local soil_plots = {soil_plot}
   if not crop_type then
      crop_type = 'stonehearth:crops:turnip_crop'
   end

   return building_service:plant_crop(session.player_id, soil_plots, crop_type, player_speficied, auto_plant, auto_harvest, true)
end

--- Returns the crops available for planting to this player
function BuildingCallHandler:get_all_crops(session)
   return {all_crops = building_service:get_all_crop_types(session)}
end

return BuildingCallHandler
