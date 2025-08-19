local get_buildable_to = function(pos)
	local def = minetest.registered_nodes[minetest.get_node(pos).name]
	return def and def.buildable_to
end

-- we use the upper 3 bits of param2 to store the last moving direction
-- lower 5 bits are reserved for the rotation
local param2s_to_moving_directions = {
	[0x00] = nil,			-- 000 00000 uninitialised
	[0x20] = "top",			-- 001 00000
	[0x40] = "bottom",		-- 010 00000
	[0x60] = "left",		-- 011 00000
	[0x80] = "right",		-- 100 00000
	[0xA0] = "deosil",		-- 101 00000
	[0xC0] = "widdershins",	-- 110 00000
	-- [0xE0] = "blocked",  -- 111 00000
}

local moving_directions_to_param2s = table.key_value_swap(param2s_to_moving_directions)

local param2_to_facedir = function (p2)
	return bit.band(p2, 0x1F)
end

local param2_to_moving_direction = function (p2)
	return param2s_to_moving_directions[bit.band(p2, 0xE0)]
end

local apply_moving_direction = function (p2, new_dir)
	return moving_directions_to_param2s[new_dir] + param2_to_facedir(p2)
end

-- Given a param2, returns a set of all the corresponding directions
local get_dirs = function(param2)
	local facedir = param2_to_facedir(param2)
	local dirs = {}
	local top = {[0]={x=0, y=1, z=0},
		{x=0, y=0, z=1},
		{x=0, y=0, z=-1},
		{x=1, y=0, z=0},
		{x=-1, y=0, z=0},
		{x=0, y=-1, z=0}}
	dirs.back = minetest.facedir_to_dir(facedir)
	dirs.top = top[math.floor(facedir/4)]
	dirs.right = {
		x=dirs.top.y*dirs.back.z - dirs.back.y*dirs.top.z,
		y=dirs.top.z*dirs.back.x - dirs.back.z*dirs.top.x,
		z=dirs.top.x*dirs.back.y - dirs.back.x*dirs.top.y
	}
	dirs.front = vector.multiply(dirs.back, -1)
	dirs.bottom = vector.multiply(dirs.top, -1)
	dirs.left = vector.multiply(dirs.right, -1)
	return dirs
end

local edge_between = function (pos1, node1, nodedef1, pos2, node2, nodedef2)
	if nodedef1._gate_edges then
		local dirs = get_dirs(node1.param2)
		for dir, offset in pairs(dirs) do
			if nodedef1._gate_edges[dir] and vector.equals(vector.add(offset, pos1), pos2) then
				return true
			end
		end
	end
	if nodedef2._gate_edges then
		local dirs = get_dirs(node2.param2)
		for dir, offset in pairs(dirs) do
			if nodedef2._gate_edges[dir] and vector.equals(vector.add(offset, pos2), pos1) then
				return true
			end
		end
	end

	return false
end

-- Returns the axis that dir points along
local dir_to_axis = function(dir)
	if dir.x ~= 0 then
		return "x"
	elseif dir.y ~= 0 then
		return "y"
	else
		return "z"
	end
end

-- Given a hinge definition, turns it into an axis and placement that can be used by the door rotation.
local interpret_hinge = function(hinge_def, pos, node_dirs)
	local axis = dir_to_axis(node_dirs[hinge_def.axis])

	local placement
	if type(hinge_def.offset) == "string" then
		placement = vector.add(pos, node_dirs[hinge_def.offset])
	elseif type(hinge_def.offset) == "table" then
		placement = vector.new(0,0,0)
		local divisor = 0
		for _, val in pairs(hinge_def.offset) do
			placement = vector.add(placement, node_dirs[val])
			divisor = divisor + 1
		end
		placement = vector.add(pos, vector.divide(placement, divisor))
	else
		placement = pos
	end
	placement[axis] = 0

	return axis, placement
end

--------------------------------------------------------------------------
-- Sliding
local check_movement_blockers = function (door, seen, possible_movement_blockers)
	for dir, position_hashes in pairs(possible_movement_blockers) do
		if door.can_slide[dir] then
			for _, position_hash in ipairs(position_hashes) do
				if not seen[position_hash] then
					door.can_slide[dir] = false
					break
				end
			end
		end
	end
end


--------------------------------------------------------------------------
-- Rotation (slightly more complex than sliding)

local facedir_rotate = {
	['x'] = {
		-- 270 degrees
		[-1] = {[0]=4, 5, 6, 7, 22, 23, 20, 21, 0, 1, 2, 3, 13, 14, 15, 12, 19, 16, 17, 18, 10, 11, 8, 9},
		-- 90 degrees
		[1] = {[0]=8, 9, 10, 11, 0, 1, 2, 3, 22, 23, 20, 21, 15, 12, 13, 14, 17, 18, 19, 16, 6, 7, 4, 5},
	},
	['y'] = {
		-- 270 degrees
		[-1] = {[0]=3, 0, 1, 2, 19, 16, 17, 18, 15, 12, 13, 14, 7, 4, 5, 6, 11, 8, 9, 10, 21, 22, 23, 20},
		-- 90 degrees
		[1] = {[0]=1, 2, 3, 0, 13, 14, 15, 12, 17, 18, 19, 16, 9, 10, 11, 8, 5, 6, 7, 4, 23, 20, 21, 22},
	},
	['z'] = {
		-- 270 degrees
		[-1] = {[0]=16, 17, 18, 19, 5, 6, 7, 4, 11, 8, 9, 10, 0, 1, 2, 3, 20, 21, 22, 23, 12, 13, 14, 15},
		-- 90 degrees
		[1] = {[0]=12, 13, 14, 15, 7, 4, 5, 6, 9, 10, 11, 8, 20, 21, 22, 23, 0, 1, 2, 3, 16, 17, 18, 19},
	}
}
	--90 degrees CW about x-axis: (x, y, z) -> (x, -z, y)
	--90 degrees CCW about x-axis: (x, y, z) -> (x, z, -y)
	--90 degrees CW about y-axis: (x, y, z) -> (-z, y, x)
	--90 degrees CCW about y-axis: (x, y, z) -> (z, y, -x)
	--90 degrees CW about z-axis: (x, y, z) -> (y, -x, z)
	--90 degrees CCW about z-axis: (x, y, z) -> (-y, x, z)
local rotate_pos = function(axis, direction, pos)
	if axis == "x" then
		if direction < 0 then
			return {x= pos.x, y= -pos.z, z= pos.y}
		else
			return {x= pos.x, y= pos.z, z= -pos.y}
		end
	elseif axis == "y" then
		if direction < 0 then
			return {x= -pos.z, y= pos.y, z= pos.x}
		else
			return {x= pos.z, y= pos.y, z= -pos.x}
		end
	else
		if direction < 0 then
			return {x= -pos.y, y= pos.x, z= pos.z}
		else
			return {x= pos.y, y= -pos.x, z= pos.z}
		end
	end
end

local rotate_pos_displaced = function(pos, origin, axis, direction)
	-- position in space relative to origin
	local newpos = vector.subtract(pos, origin)
	newpos = rotate_pos(axis, direction, newpos)
	-- Move back to original reference frame
	return vector.add(newpos, origin)
end

local rotation_position_iterator = function (pos1, pos2, axis1, axis2)
	local current_pos = vector.new(pos1)
	local steps = vector.sign(vector.subtract(pos2, pos1))
	return function ()
		if current_pos[axis1] ~= pos2[axis1] then
			current_pos[axis1] = current_pos[axis1] + steps[axis1]
		elseif current_pos[axis2] ~= pos2[axis2] then
			current_pos[axis2] = current_pos[axis2] + steps[axis2]
		else
			return nil
		end
		return current_pos
	end
end

local check_swings = function (door)
	local swings = {
		[1] = true,
		[-1] = true
	}
	local dir1 = dir_to_axis(door.directions.back)
	local dir2 = (
			(dir1 ~= "x" and door.hinge.axis ~= "x" and "x") or
			(dir1 ~= "y" and door.hinge.axis ~= "y" and "y") or
			(dir1 ~= "z" and door.hinge.axis ~= "z" and "z")
	)

	for _, part in ipairs(door.all) do
		local pos1 = part.pos
		for direction = -1, 1, 2 do
			if swings[direction] then
				local pos2 = rotate_pos_displaced(pos1, door.hinge.placement, door.hinge.axis, direction)
				for check_pos in rotation_position_iterator(pos1, pos2, dir1, dir2) do
					if not get_buildable_to(check_pos) then
						swings[direction] = false
						if not swings[-direction] then
							-- door can't move, no need to check other positions
							return swings
						end
						break
					end
				end
			end
		end
	end
	return swings
end

local get_door_layout = function(pos, param2, player)
	if param2_to_facedir(param2) > 23 then
		--[[ A bug in another mod once resulted in bad param2s being written to nodes, this will at least prevent
		     crashes if something like that happens again.]]
		return nil
	end

	-- This method does a depth-first-search for all nodes that meet the following criteria:
	-- belongs to a "castle_gate" group
	-- has the same "back" direction as the initial node
	-- is accessible via up, down, left or right directions unless one of those directions goes through an edge that
	-- one of the two nodes has marked as a gate edge

	local start_node = minetest.get_node(pos)
	local start_def = minetest.registered_nodes[start_node.name]
	local group_value = start_def and start_def.groups.castle_gate
	if group_value == nil then
		-- seems like the door disappeared during the .after
		return
	end
	local search_directions = get_dirs(start_node.param2)
	search_directions.front = nil
	search_directions.back = nil


	local door = {}

	door.all = {{pos=pos, node=start_node}}
	door.contains_protected_node = false
	door.directions = get_dirs(param2)
	door.previous_move = param2_to_moving_direction(param2)
	door.can_slide = {top=true, bottom=true, left=true, right=true}


	local stack = {pos}		-- all gatepositions where we haven't seen all neighbours
	local seen = {[minetest.hash_node_position(pos)] = true}
	-- edges with a gate behind might block a sliding direction when they are non part of the door
	-- we can't know whether they are part of the door, so we check these positions once we know the whole door
	local possible_movement_blockers = {
		top = {},
		bottom = {},
		left = {},
		right = {}
	}

	while #stack > 0 do
		local current_pos = stack[#stack]
		stack[#stack] = nil

		local current_node = minetest.get_node(current_pos)
		local current_nodedef = minetest.registered_nodes[current_node.name]

		if current_nodedef._gate_hinge then
			local node_directions = get_dirs(current_node.param2)
			local axis, placement = interpret_hinge(current_nodedef._gate_hinge, current_pos, node_directions)
			if door.hinge == nil then -- this is the first hinge we've encountered.
				door.hinge = {axis=axis, placement=placement}
			else
				if door.hinge.axis ~= axis or not vector.equals(door.hinge.placement, placement) then
					return
				end
			end
		end

		for dir, offset in pairs(search_directions) do
			local search_pos = vector.add(current_pos, offset)
			local hash = minetest.hash_node_position(search_pos)
			if not seen[hash] then -- no continue :/
				local search_node = minetest.get_node(search_pos)
				local search_node_def = minetest.registered_nodes[search_node.name]
				if search_node_def and search_node_def.groups.castle_gate == group_value then
					if edge_between(current_pos, current_node, current_nodedef, search_pos, search_node, search_node_def) then
						table.insert(possible_movement_blockers[dir], minetest.hash_node_position(search_pos))
					else
						table.insert(door.all, {pos=search_pos, node=search_node})
						seen[hash] = true
						table.insert(stack, search_pos)
					end
				elseif not get_buildable_to(search_pos) then
					door.can_slide[dir] = false
				end
			end
		end
	end

	if not door.hinge then
		check_movement_blockers(door, seen, possible_movement_blockers)
	else
		door.can_slide = nil
		door.swings = check_swings(door)
	end

	return door
end


local slide_gate = function(door, direction)
	for _, door_node in ipairs(door.all) do
		minetest.set_node(door_node.pos, {name="air"})
		door_node.pos = vector.add(door_node.pos, door.directions[direction])
	end
	for _, door_node in ipairs(door.all) do
		door_node.node.param2 = apply_moving_direction(door_node.node.param2, direction)
		minetest.set_node(door_node.pos, door_node.node)
	end
end

local rotate_door = function (door, direction, direction_str)
	if not door.swings[direction] then
		return false
	end

	local origin = door.hinge.placement
	local axis = door.hinge.axis

	for _, door_node in ipairs(door.all) do
		minetest.set_node(door_node.pos, {name="air"})
		door_node.pos = rotate_pos_displaced(door_node.pos, origin, axis, direction)
		door_node.node.param2 = facedir_rotate[axis][direction][param2_to_facedir(door_node.node.param2)]
		door_node.node.param2 = apply_moving_direction(door_node.node.param2, direction_str)
		minetest.set_node(door_node.pos, door_node.node)
	end
	return true
end

castle_gates.process_gate = function(pos, node, player, moving_direction)
	if not player or not player:get_pos() then
		return -- Player left; invalid ObjectRef
	end

	local door = get_door_layout(pos, node.param2, player)

	if door ~= nil then
		local door_moved = false
		-- this door was just triggered
		if not moving_direction then
			if door.can_slide ~= nil then
				if door.previous_move and door.can_slide[door.previous_move] then
					moving_direction = door.previous_move
				elseif door.previous_move == "top" and door.can_slide.bottom then
					moving_direction = "bottom"
				elseif door.previous_move == "bottom" and door.can_slide.top then
					moving_direction = "top"
				elseif door.previous_move == "left" and door.can_slide.right then
					moving_direction = "right"
				elseif door.previous_move == "right" and door.can_slide.left then
					moving_direction = "left"
				else
					-- find any open direction
					for slide_dir, enabled in pairs(door.can_slide) do
						if enabled then
							moving_direction = slide_dir
							break
						end
					end
				end
			elseif door.hinge ~= nil then
				if door.swings[-1] and not (door.swings[1] and door.previous_move == "deosil") then
					moving_direction = "widdershins"
				else
					moving_direction = "deosil"
				end
			end
		end

		if door.can_slide and door.can_slide[moving_direction] then
			slide_gate(door, moving_direction)
			door_moved = true
		elseif door.hinge ~= nil then -- this is a hinged door
			if moving_direction == "deosil" then
				door_moved = rotate_door(door, 1, "deosil")
			elseif moving_direction == "widdershins" then
				door_moved = rotate_door(door, -1, "widdershins")
			end
		end

		if door_moved then
			minetest.after(1, function(player_name)
				-- Get current player ObjectRef (nil when gone)
				if door.all[1] then -- Prevent crashes if gate got deleted (e.g. worldedit)
					castle_gates.process_gate(door.all[1].pos, door.all[1].node,
						minetest.get_player_by_name(player_name), moving_direction)
				end
			end, player:get_player_name())
		end
	end
end


----------------------------------------------------------------------------------------------------
-- When creating new gate pieces use this as the "on_rightclick" method of their node definitions
-- if you want the player to be able to trigger the gate by clicking on that particular node.
-- If you just want the node to move with the gate and not trigger it this isn't necessary,
-- only the "castle_gate" group is needed for that.
castle_gates.trigger_gate = function (pos, node, player)
	return castle_gates.process_gate(pos, node, player)
end