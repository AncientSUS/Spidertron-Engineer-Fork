--control.lua
require "util"
require("utils.table-utils")
require("utils.get-banned-items")
spidertron_lib = require("utils.spidertron_lib")

spidertron_researches = {"military", "military-2", "power-armor", "power-armor-mk2", "spidertron"}
spidertron_names = {"spidertron-engineer-0", "spidertron-engineer-1", "spidertron-engineer-2", "spidertron-engineer-3", "spidertron-engineer-4", "spidertron-engineer-5"}
train_names = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}
drivable_names = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", "car", "spider-vehicle"}

inventory_types = {"cargo-wagon", "container", "car", "character", "logistic-container", "spider-vehicle"}
inventory_defines = {
    ["cargo-wagon"] = {defines.inventory.cargo_wagon},
    ["container"] = {defines.inventory.chest},
    ["car"] = {defines.inventory.car_trunk},
    ["character"] = {defines.inventory.character_main, defines.inventory.character_guns, defines.inventory.character_armor, defines.inventory.character_trash},
    ["logistic-container"] = {defines.inventory.chest},
    ["spider-vehicle"] = {defines.inventory.spider_trunk, defines.inventory.spider_trash}
}

local spidertron_filters = {
    {filter = "name", name = "spidertron-engineer-0"},
    {filter = "name", name = "spidertron-engineer-1"},
    {filter = "name", name = "spidertron-engineer-2"},
    {filter = "name", name = "spidertron-engineer-3"},
    {filter = "name", name = "spidertron-engineer-4"},
    {filter = "name", name = "spidertron-engineer-5"}
}

heal_amount = 1

-- Инициализация storage
local function init_storage()
    storage = storage or {}
    storage.spidertrons = storage.spidertrons or {}
    storage.spidertrons_to_heal = storage.spidertrons_to_heal or {}
    storage.spawn_with_remote = storage.spawn_with_remote or {}
    storage.pending_player_starts = storage.pending_player_starts or {}
    storage.player_last_driving_change_tick = storage.player_last_driving_change_tick or {}
    storage.spidertron_saved_data = storage.spidertron_saved_data or {}
    storage.registered_spidertrons = storage.registered_spidertrons or {}
    storage.spidertron_unit_to_player = storage.spidertron_unit_to_player or {}
    storage.spidertron_destroyed_by_script = storage.spidertron_destroyed_by_script or {}
    storage.script_placed_into_vehicle = storage.script_placed_into_vehicle or {}
    storage.force_spidertron_level = storage.force_spidertron_level or {}
    storage.spidertron_saved_data_trunk_filters = storage.spidertron_saved_data_trunk_filters or {}
    storage.banned_items = storage.banned_items or {}
    storage.allowed_to_leave = storage.allowed_to_leave or "never"
    storage.allowed_into_entities = storage.allowed_into_entities or "none"
    storage.upgrading = storage.upgrading or false
    storage.first_setup_done = storage.first_setup_done or false
end

local function safe_game_prototype(key)
    local ok, prototypes = pcall(function() return game[key] end)
    return ok and prototypes or nil
end

-- repair function
local function create_spidertron_repair_cloud(event)
    local player = game.players[event.player_index]
    if player then
        if (player.vehicle and player.vehicle.remove_item({name="repair-pack", count=1}) == 1) or (player.remove_item({name="repair-pack", count=1}) == 1) then
            player.surface.create_entity({name="spidertron-repair-cloud", position=player.position})
        else
            player.print({"message.no-repair-packs"})
        end
    else
        game.print("No player found")
    end
end

script.on_event(defines.events.on_lua_shortcut, function(event)
    if event.prototype_name == "spidertron-repair" then
        create_spidertron_repair_cloud(event)
    end
end)
script.on_event("spidertron-repair", create_spidertron_repair_cloud)

script.on_event(defines.events.on_entity_damaged, function(event)
    init_storage()
    if event.entity.unit_number then
        storage.spidertrons_to_heal[event.entity.unit_number] = event.entity
    end
end, spidertron_filters)

script.on_nth_tick(20, function(event)
    init_storage()
    if next(storage.spidertrons_to_heal) then
        for k, v in pairs(storage.spidertrons_to_heal) do
            if v.valid then
                v.health = v.health + heal_amount
                if v.get_health_ratio() == 1 then
                    storage.spidertrons_to_heal[v.unit_number] = nil
                end
            else
                storage.spidertrons_to_heal[k] = nil
                log("Spidertron is invalid")
            end
        end
    end
end)

local function get_remote(player, not_connected)
    local spidertron = storage.spidertrons[player.index]
    local inventory = player.get_main_inventory()
    if (spidertron and spidertron.valid) or not_connected then
        for i = 1, #inventory do
            local item = inventory[i]
            if item.valid_for_read then
                if not_connected then
                    if item.prototype.type == "spidertron-remote" and not item.connected_entity then
                        return item
                    end
                elseif item.connected_entity == spidertron then
                    return item
                end
            end
        end
    end
end

local player_start
local get_spawn_with_remote

local function process_pending_player_starts()
    if not storage.pending_player_starts then
        script.on_nth_tick(1, nil)
        return
    end
    for player_index, _ in pairs(storage.pending_player_starts) do
        local pending_player = game.get_player(player_index)
        if pending_player and pending_player.character then
            storage.pending_player_starts[player_index] = nil
            player_start(pending_player)
        end
    end
    if not next(storage.pending_player_starts) then
        script.on_nth_tick(1, nil)
    end
end

local function schedule_player_start(player)
    if not player or not player.index then return end
    if player.character then
        player_start(player)
        return
    end
    storage.pending_player_starts = storage.pending_player_starts or {}
    storage.pending_player_starts[player.index] = true
    script.on_nth_tick(1, process_pending_player_starts)
end

local function store_spidertron_data(player)
    local spidertron = storage.spidertrons[player.index]
    storage.script_placed_into_vehicle[player.index] = true
    storage.spidertron_saved_data[player.index] = spidertron_lib.serialise_spidertron(spidertron)
    storage.script_placed_into_vehicle[player.index] = false
end

local function place_stored_spidertron_data(player, transfer_player_state)
    local saved_data = storage.spidertron_saved_data[player.index]
    local spidertron = storage.spidertrons[player.index]
    log("Placing saved data back into spidertron:")
    spidertron_lib.deserialise_spidertron(spidertron, saved_data, transfer_player_state)
    storage.spidertron_saved_data[player.index] = nil
end

local function replace_spidertron(player, name)
    if storage.upgrading then return end
    storage.upgrading = true

    local previous_spidertron = storage.spidertrons[player.index]
    if not name then
        local level = storage.force_spidertron_level[player.force.index] or 0
        name = "spidertron-engineer-" .. level
    end

    log("Upgrading spidertron to level " .. name .. " for player " .. player.name)

    local last_user = previous_spidertron.last_user
    local driver = previous_spidertron.get_driver()

    -- Сохраняем данные старого
    store_spidertron_data(player)

    -- Запоминаем позицию и направление
    local position = previous_spidertron.position
    local direction = previous_spidertron.direction
    local force = previous_spidertron.force
    local surface = previous_spidertron.surface

    -- Уничтожаем старого паука ДО создания нового, чтобы избежать дублирования
    storage.spidertron_destroyed_by_script[previous_spidertron.unit_number] = true
    previous_spidertron.destroy()
    storage.spidertrons[player.index] = nil

    -- Создаём нового
    local spidertron = surface.create_entity{
        name = name,
        position = position,
        direction = direction,
        force = force,
        fast_replace = true,
        spill = false,
        create_build_effect_smoke = true
    }
    if not spidertron then
        player.teleport(1)
        storage.upgrading = false
        replace_spidertron(player, name)
        return
    end

    if last_user then
        spidertron.last_user = last_user
    end

    storage.spidertrons[player.index] = spidertron
    storage.spidertron_unit_to_player[spidertron.unit_number] = player.index

    -- Восстанавливаем данные
    place_stored_spidertron_data(player, true)

    -- Если игрок был внутри старого, сажаем его в нового
    if driver and driver.valid and driver == player.character then
        spidertron.set_driver(player)
    end

    spidertron.color = player.color
    storage.upgrading = false
    return spidertron
end

local function ensure_player_is_in_correct_spidertron(player, entity)
    if not player or not player.character then
        log("Not creating spidertron for player - player or character does not exist")
        return
    end

    local spidertron = storage.spidertrons[player.index]
    local previous_spidertron_data = storage.spidertron_saved_data[player.index]

    -- Проверка: если игрок уже в разрешённом транспорте (поезд и т.п.) – не трогаем
    if previous_spidertron_data and player.driving and
        (storage.allowed_into_entities == "all" or
         (storage.allowed_into_entities == "limited" and contains(train_names, player.vehicle.type))) then
        log("Player in train or allowed vehicle. Left alone")
        return
    end
    local active_mods = safe_game_prototype("active_mods")
    if active_mods and active_mods["TheFatController"] and player.driving and player.vehicle and player.vehicle.type == "locomotive" then
        return
    end

    -- Определяем целевой уровень
    local spidertron_level = storage.force_spidertron_level[player.force.index] or 0
    local target_name = "spidertron-engineer-" .. spidertron_level

    -- Если паук существует, но не соответствует уровню – заменяем
    if spidertron and spidertron.valid then
        if target_name ~= spidertron.name then
            replace_spidertron(player)
            spidertron = storage.spidertrons[player.index]
        end
    else
        -- Создаём нового, если нет
        log("Creating spidertron for player " .. player.name)
        spidertron = player.surface.create_entity{
            name = target_name,
            position = player.position,
            force = player.force,
            player = player,
            create_build_effect_smoke = true
        }
        if not spidertron then
            player.teleport(1)
            ensure_player_is_in_correct_spidertron(player, entity)
            return
        end
        storage.spidertrons[player.index] = spidertron
        storage.spidertron_unit_to_player[spidertron.unit_number] = player.index
        local ok, register_on_entity_destroyed = pcall(function() return script.register_on_entity_destroyed end)
        if ok and register_on_entity_destroyed then
            local reg_id = register_on_entity_destroyed(spidertron)
            if reg_id then
                storage.registered_spidertrons[reg_id] = player
            end
        end
        spidertron.color = player.color
        if previous_spidertron_data then
            place_stored_spidertron_data(player, false)
        end
    end

    if not spidertron then
        log("Spidertron could not be created. Moving player 1 tile to the right and trying again")
        player.teleport(1)
        ensure_player_is_in_correct_spidertron(player)
        return
    end

    -- Посадка игрока в паука, если он не в правильном транспорте
    if player.driving and contains(spidertron_names, player.vehicle.name) and player.vehicle == spidertron then
        log("Already in correct spidertron")
        return
    else
        if player.driving then
            log("Vehicle " .. player.vehicle.name .. " is not a valid vehicle, exiting")
            storage.script_placed_into_vehicle[player.index] = true
            player.driving = false
            storage.script_placed_into_vehicle[player.index] = false
        end

        local allowed_to_leave = contains({"limited-time", "unlimited-time"}, storage.allowed_to_leave)
        if (not allowed_to_leave) or (allowed_to_leave and (not entity or (not contains(spidertron_names, entity.name) and previous_spidertron_data))) then
            storage.script_placed_into_vehicle[player.index] = true
            spidertron.set_driver(player)
            storage.script_placed_into_vehicle[player.index] = false

            if spidertron.get_health_ratio() < 1 then
                storage.spidertrons_to_heal[spidertron.unit_number] = spidertron
            end

            if not player.driving and player.vehicle ~= spidertron then
                error("Something has interfered with .set_driver()")
            end
        else
            log("Settings allow player to leave spidertron")
        end
    end
end

local function upgrade_spidertrons(force)
    for _, player in pairs(force.players) do
        ensure_player_is_in_correct_spidertron(player)
        -- Удаляем лишние предметы спайдертронов из инвентаря игрока
        for i = 0, 5 do
            player.remove_item({name = "spidertron-engineer-" .. i})
        end
    end
end

player_start = function(player)
    if not player then
        log("Can't set up player - no player object")
        return
    end

    if not player.character then
        log("Deferring player start for " .. (player.name or "unknown player") .. " because character is not available yet")
        storage.pending_player_starts = storage.pending_player_starts or {}
        storage.pending_player_starts[player.index] = true
        script.on_nth_tick(1, process_pending_player_starts)
        return
    end

    if storage.pending_player_starts then
        storage.pending_player_starts[player.index] = nil
    end

    log("Setting up player " .. player.name)
    ensure_player_is_in_correct_spidertron(player)

    for _, item_stack in pairs(storage.banned_items) do
        remove_from_inventory(item_stack, player.character)
    end

    if get_spawn_with_remote(player) then
        player.insert("spidertron-remote")
        local remote = get_remote(player, true)
        if remote then
            remote.connected_entity = storage.spidertrons[player.index]
        end
    end
end

-- События игрока
script.on_event(defines.events.on_cutscene_cancelled, function(event) schedule_player_start(game.get_player(event.player_index)) end)
script.on_event(defines.events.on_player_respawned, function(event) schedule_player_start(game.get_player(event.player_index)) end)
script.on_event(defines.events.on_player_created, function(event) schedule_player_start(game.get_player(event.player_index)) end)
script.on_event(defines.events.on_player_joined_game, function(event) schedule_player_start(game.get_player(event.player_index)) end)

script.on_event(defines.events.on_player_changed_surface, function(event)
    log("on_player_changed_surface - player " .. event.player_index)
    local function on_tick_after_changed_surface(inner_event)
        local player = game.get_player(event.player_index)
        local spidertron = storage.spidertrons[player.index]
        if spidertron then
            store_spidertron_data(player)
            storage.spidertron_destroyed_by_script[spidertron.unit_number] = true
            spidertron.destroy()
            storage.spidertrons[player.index] = nil
        end
        ensure_player_is_in_correct_spidertron(player)
        script.on_nth_tick(inner_event.tick, nil)
    end
    script.on_nth_tick(event.tick + 1, on_tick_after_changed_surface)
end)

script.on_event(defines.events.on_player_driving_changed_state, function(event)
    if storage.player_last_driving_change_tick[event.player_index] == event.tick or storage.script_placed_into_vehicle[event.player_index] then
        return
    end
    storage.player_last_driving_change_tick[event.player_index] = event.tick
    local player = game.get_player(event.player_index)
    local spidertron = storage.spidertrons[player.index]
    local allowed_into_entities = storage.allowed_into_entities
    if not player.driving and spidertron and allowed_into_entities ~= "none" and event.entity and contains(spidertron_names, event.entity.name) then
        log("Searching for nearby entities to enter")
        for radius = 1, 5 do
            local nearby_entities
            if allowed_into_entities == "limited" then
                nearby_entities = player.surface.find_entities_filtered{position = spidertron.position, radius = radius, type = train_names}
            elseif allowed_into_entities == "all" then
                nearby_entities = player.surface.find_entities_filtered{position = spidertron.position, radius = radius, type = drivable_names}
            end
            for _, entity_to_drive in pairs(nearby_entities) do
                if entity_to_drive ~= spidertron and not contains(spidertron_names, entity_to_drive.name) and not entity_to_drive.get_driver() and entity_to_drive.prototype.allow_passengers then
                    log("Found entity to drive: " .. entity_to_drive.name)
                    entity_to_drive.set_driver(player)
                    store_spidertron_data(player)
                    storage.spidertron_destroyed_by_script[spidertron.unit_number] = true
                    spidertron.destroy()
                    storage.spidertrons[player.index] = nil
                    return
                end
            end
        end
    end
    ensure_player_is_in_correct_spidertron(player, event.entity)
end)

script.on_event(defines.events.on_player_toggled_map_editor, function(event)
    ensure_player_is_in_correct_spidertron(game.get_player(event.player_index))
end)

local function deal_damage()
    for _, player in pairs(game.players) do
        if player.character and player.character.is_entity_with_health and not player.driving then
            player.character.damage(10, "neutral")
        end
    end
end

local function get_spawn_with_remote_setting(player_index)
    if not player_index then return false end
    local ok, player_settings_table = pcall(function() return settings.player end)
    if not ok or not player_settings_table then return false end
    local player_settings = player_settings_table[player_index]
    if player_settings and player_settings["spidertron-engineer-spawn-with-remote"] then
        return player_settings["spidertron-engineer-spawn-with-remote"].value
    end
    return false
end

local function settings_changed(event)
    init_storage()
    storage.allowed_to_leave = settings.global["spidertron-engineer-allowed-out-of-spidertron"].value
    if storage.allowed_to_leave == "limited-time" then
        script.on_nth_tick(31, deal_damage)
    else
        script.on_nth_tick(31, nil)
        if storage.allowed_to_leave == "never" then
            for _, player in pairs(game.players) do
                ensure_player_is_in_correct_spidertron(player)
            end
        end
    end

    storage.allowed_into_entities = settings.global["spidertron-engineer-allowed-into-entities"].value

    if event and event.player_index then
        local previous_setting = storage.spawn_with_remote[event.player_index]
        local current_setting = get_spawn_with_remote_setting(event.player_index)
        storage.spawn_with_remote[event.player_index] = current_setting
        if current_setting and not previous_setting then
            local player = game.get_player(event.player_index)
            if player then schedule_player_start(player) end
        end
    end
end
script.on_event(defines.events.on_runtime_mod_setting_changed, settings_changed)

get_spawn_with_remote = function(player)
    return player and storage.spawn_with_remote and storage.spawn_with_remote[player.index]
end

local function get_item_prototypes_by_type(type_name)
    local items = {}
    local prototypes = safe_game_prototype("item_prototypes")
    if prototypes then
        for name, prototype in pairs(prototypes) do
            if prototype.type == type_name then
                items[name] = prototype
            end
        end
    end
    return items
end

local function get_all_recipe_prototypes()
    local recipes = {}
    local prototypes = safe_game_prototype("recipe_prototypes")
    if prototypes then
        for name, prototype in pairs(prototypes) do
            recipes[name] = prototype
        end
    end
    return recipes
end

local function setup()
    log("SpidertronEngineer setup() start")
    init_storage()

    for _, player in pairs(game.players) do
        storage.spawn_with_remote[player.index] = get_spawn_with_remote_setting(player.index)
    end
    storage.player_last_driving_change_tick = {}
    storage.spidertron_saved_data_trunk_filters = storage.spidertron_saved_data_trunk_filters or {}

    storage.banned_items = get_banned_items(
        get_item_prototypes_by_type("gun"),
        get_item_prototypes_by_type("armor"),
        get_all_recipe_prototypes()
    )
    for _, name in pairs(spidertron_names) do
        table.insert(storage.banned_items, name)
    end

    for _, force in pairs(game.forces) do
        -- Вычисляем текущий уровень
        local level = 0
        for _, research in pairs(spidertron_researches) do
            if force.technologies[research].researched then
                level = level + 1
            end
        end
        local previous_level = storage.force_spidertron_level[force.index] or 0
        
        -- Корректируем бонус инвентаря
        force.character_inventory_slots_bonus = force.character_inventory_slots_bonus - 10 * previous_level + 10 * level
        storage.force_spidertron_level[force.index] = level

        -- Бонусы досягаемости устанавливаем только один раз
        if not storage.first_setup_done then
            local resource_reach_distance = game.forces["player"].character_resource_reach_distance_bonus
            force.character_resource_reach_distance_bonus = resource_reach_distance + 3
            local build_distance_bonus = game.forces["player"].character_build_distance_bonus
            force.character_build_distance_bonus = build_distance_bonus + 3
            local reach_distance_bonus = game.forces["player"].character_reach_distance_bonus
            force.character_reach_distance_bonus = reach_distance_bonus + 3
        end
    end
    storage.first_setup_done = true

    for _, force in pairs(game.forces) do
        for name, _ in pairs(force.recipes) do
            if contains(storage.banned_items, name) and force.recipes[name].enabled then
                force.recipes[name].enabled = false
                for _, surface in pairs(game.surfaces) do
                    for _, entity in pairs(surface.find_entities_filtered{type = "assembling-machine", force = force}) do
                        local recipe = entity.get_recipe()
                        if recipe and recipe.name == name then
                            entity.set_recipe(nil)
                        end
                    end
                end
            end
        end

        local item_prototypes = safe_game_prototype("item_prototypes")
        if item_prototypes then
            for name, _ in pairs(item_prototypes) do
                if contains(storage.banned_items, name) then
                    for _, surface in pairs(game.surfaces) do
                        for _, entity in pairs(surface.find_entities_filtered{type = inventory_types, force = force}) do
                            remove_from_inventory(name, entity)
                        end
                    end
                end
            end
        end

        if force.technologies["space-science-pack"] and force.technologies["space-science-pack"].researched and settings.startup["spidertron-engineer-space-science-to-fish"].value then
            force.recipes["spidertron-engineer-raw-fish"].enabled = true
        end
    end

    settings_changed()

    for _, player in pairs(game.players) do
        player_start(player)
    end

    log("Finished setup()")
end

local function config_changed_setup(changed_data)
    init_storage()
    log("Configuration changed data: " .. serpent.block(changed_data))
    local this_mod_data = changed_data.mod_changes["SpidertronEngineer"]
    if (not this_mod_data) or this_mod_data["old_version"] then
        setup()
    end

    storage.banned_items = get_banned_items(
        get_item_prototypes_by_type("gun"),
        get_item_prototypes_by_type("armor"),
        get_all_recipe_prototypes()
    )
    for _, name in pairs(spidertron_names) do
        table.insert(storage.banned_items, name)
    end

    if this_mod_data and this_mod_data["old_version"] and changed_data.mod_startup_settings_changed then
        for _, player in pairs(game.players) do
            if contains(spidertron_names, player.vehicle) then
                replace_spidertron(player, "spidertron-engineer-5a")
                local spidertron = replace_spidertron(player)
                spidertron.color = player.color
                storage.spidertrons[player.index] = spidertron
                spidertron.set_driver(player)
            end
        end
    end

    local old_version
    local mod_changes = changed_data.mod_changes
    if mod_changes and mod_changes["SpidertronEngineer"] and mod_changes["SpidertronEngineer"]["old_version"] then
        old_version = mod_changes["SpidertronEngineer"]["old_version"]
    else
        return
    end

    old_version = util.split(old_version, ".")
    for i = 1, #old_version do
        old_version[i] = tonumber(old_version[i])
    end
    if old_version[1] == 1 then
        if old_version[2] <= 6 and old_version[3] < 3 then
            log("Running pre-1.6.3 migration")
            for _, spidertron_data in pairs(storage.spidertron_saved_data) do
                local previous_trunk = spidertron_data.trunk
                local trunk_inventory = game.create_inventory(500)
                for name, count in pairs(previous_trunk) do
                    trunk_inventory.insert({name = name, count = count})
                end
                spidertron_data.trunk = trunk_inventory
                local previous_ammo = spidertron_data.ammo
                local ammo_inventory = game.create_inventory(500)
                for name, count in pairs(previous_ammo) do
                    ammo_inventory.insert({name = name, count = count})
                end
                spidertron_data.ammo = ammo_inventory
            end
        end
        if old_version[2] < 8 then
            log("Running pre-1.8.0 migration")
            for player_index, saved_data in pairs(storage.spidertron_saved_data) do
                local filter_data = storage.spidertron_saved_data_trunk_filters[player_index][defines.inventory.spider_trunk]
                saved_data.trunk = {inventory = saved_data.trunk, filters = filter_data}
                saved_data.ammo = {inventory = saved_data.ammo}
                saved_data.vehicle_automatic_targeting_parameters = saved_data.auto_target
                local player = game.get_player(player_index)
                local remote = get_remote(player, true)
                if remote then
                    saved_data.connected_remotes = {remote}
                end
            end
            storage.spidertron_saved_data_trunk_filters = nil
        end
    end
end

local function space_exploration_compat()
    if remote.interfaces["space-exploration"] then
        local on_player_respawned = remote.call("space-exploration", "get_on_player_respawned_event")
        if on_player_respawned then
            script.on_event(on_player_respawned, function(event)
                log("SE: on_player_respawned")
                local player = game.get_player(event.player_index)
                local spidertron = storage.spidertrons[player.index]
                if spidertron and spidertron.valid then
                    on_spidertron_died(spidertron, player, true)
                end
                schedule_player_start(game.get_player(event.player_index))
            end)
        end
    end
end

script.on_load(function()
    space_exploration_compat()
end)

script.on_init(function()
    init_storage()
    space_exploration_compat()
    setup()
end)

script.on_configuration_changed(config_changed_setup)

function on_spidertron_died(spidertron, player, keep_player)
    if not player then player = spidertron.last_user end
    if spidertron and get_spawn_with_remote(player) then
        local remote = get_remote(player)
        if remote then remote.clear() end
    end
    if keep_player then
        if spidertron then
            spidertron.set_driver(nil)
            storage.spidertron_destroyed_by_script[spidertron.unit_number] = true
            spidertron.destroy()
        end
    else
        if player.character then
            log("Killing player " .. player.name)
            player.character.die("neutral")
        end
    end
    storage.spidertrons[player.index] = nil
    storage.spidertron_saved_data[player.index] = nil
end

script.on_event(defines.events.on_entity_died, function(event)
    init_storage()
    local spidertron = event.entity
    storage.spidertron_destroyed_by_script[spidertron.unit_number] = true
    on_spidertron_died(spidertron)
end, spidertron_filters)

if defines.events.on_entity_destroyed then
    script.on_event(defines.events.on_entity_destroyed, function(event)
        init_storage()
        local unit_number = event.unit_number
        if unit_number then
            if storage.spidertron_destroyed_by_script[unit_number] then
                storage.spidertron_destroyed_by_script[unit_number] = nil
                storage.spidertron_unit_to_player[unit_number] = nil
                return
            end
            local player_index = storage.spidertron_unit_to_player[unit_number]
            if player_index then
                local player = game.get_player(player_index)
                if player then
                    on_spidertron_died(nil, player)
                end
                storage.spidertron_unit_to_player[unit_number] = nil
                storage.spidertrons[player_index] = nil
            else
                local reg_id = event.registration_number
                if reg_id and storage.registered_spidertrons and storage.registered_spidertrons[reg_id] then
                    local player = storage.registered_spidertrons[reg_id]
                    on_spidertron_died(nil, player)
                    storage.registered_spidertrons[reg_id] = nil
                end
            end
        end
    end)
end

script.on_event(defines.events.on_pre_player_died, function(event)
    init_storage()
    local player = game.get_player(event.player_index)
    if get_spawn_with_remote(player) then
        local remote = get_remote(player)
        if remote then remote.clear() end
    end
end)

script.on_event(defines.events.on_player_died, function(event)
    init_storage()
    local player = game.get_player(event.player_index)
    local spidertron = storage.spidertrons[player.index]
    if spidertron and spidertron.valid then
        log("Player died outside of spidertron")
        spidertron.die("neutral")
    end
end)

script.on_event({defines.events.on_player_left_game, defines.events.on_player_kicked, defines.events.on_player_banned}, function(event)
    init_storage()
    local spidertron = storage.spidertrons[event.player_index]
    if spidertron and spidertron.valid then
        store_spidertron_data({index = event.player_index})
        storage.spidertron_destroyed_by_script[spidertron.unit_number] = true
        spidertron.destroy()
    end
end)

script.on_event(defines.events.on_gui_closed, function(event)
    init_storage()
    local player = game.get_player(event.player_index)
    if not player then return end
    local spidertron = storage.spidertrons and storage.spidertrons[player.index]
    if spidertron and spidertron.valid then
        spidertron.color = player.color
    end
end)

script.on_event(defines.events.on_research_finished, function(event)
    init_storage()
    local research = event.research
    if contains(spidertron_researches, research.name) then
        local force = research.force
        force.character_inventory_slots_bonus = force.character_inventory_slots_bonus + 10
        if storage.force_spidertron_level[force.index] == nil then
            storage.force_spidertron_level[force.index] = 0
        end
        storage.force_spidertron_level[force.index] = storage.force_spidertron_level[force.index] + 1
        upgrade_spidertrons(force)
    end
end)

script.on_event(defines.events.on_research_reversed, function(event)
    init_storage()
    local research = event.research
    if contains(spidertron_researches, research.name) then
        local force = research.force
        force.character_inventory_slots_bonus = force.character_inventory_slots_bonus - 10
        if storage.force_spidertron_level[force.index] == nil then
            storage.force_spidertron_level[force.index] = 0
        end
        storage.force_spidertron_level[force.index] = storage.force_spidertron_level[force.index] - 1
        upgrade_spidertrons(force)
    end
end)

script.on_event(defines.events.on_force_created, function(event)
    init_storage()
    storage.force_spidertron_level[event.force.index] = 0
end)

script.on_event(defines.events.on_force_reset, function(event)
    init_storage()
    local force = event.force
    local spidertron_level = storage.force_spidertron_level[force.index] or 0
    force.character_inventory_slots_bonus = force.character_inventory_slots_bonus - 10 * spidertron_level
    storage.force_spidertron_level[force.index] = 0
end)

script.on_event(defines.events.on_technology_effects_reset, function(event)
    init_storage()
    for _, player in pairs(event.force.players) do
        if player.character then
            for _, name in pairs(spidertron_names) do
                remove_from_inventory(name, player.character)
            end
        end
    end
end)

script.on_event(defines.events.on_player_used_capsule, function(event)
    init_storage()
    local player = game.get_player(event.player_index)
    local item_name = event.item.name
    local active_mods = safe_game_prototype("active_mods")
    if active_mods and active_mods["space-exploration"] then
        if item_name == "se-medpack" then
            storage.spidertrons[player.index].damage(-50, player.force, "poison")
        elseif item_name == "se-medpack-2" then
            storage.spidertrons[player.index].damage(-100, player.force, "poison")
        elseif item_name == "se-medpack-3" then
            storage.spidertrons[player.index].damage(-200, player.force, "poison")
        elseif item_name == "se-medpack-4" then
            storage.spidertrons[player.index].damage(-400, player.force, "poison")
        end
    else
        if item_name == "raw-fish" then
            log("Fish eaten by " .. player.name)
            storage.spidertrons[player.index].damage(-80, player.force, "poison")
        end
    end
end)

commands.add_command("create-spidertron",
    "Usage: `/create-spidertron [playername]`. Creates a spidertron for user or the specified player.",
    function(data)
        local player_name = data.parameter
        local player = player_name and game.get_player(player_name) or game.get_player(data.player_index)
        if player then
            ensure_player_is_in_correct_spidertron(player)
        else
            game.print("Can't find player")
        end
    end
)
