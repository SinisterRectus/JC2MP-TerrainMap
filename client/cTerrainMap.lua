class 'TerrainMap'

function TerrainMap:__init()

	self.cell_size = 128 -- Cell edge length (0-127 inclusive)
	self.xz_step = 2 -- XZ resolution, should be an integer
	self.y_min_step = 2 -- Y Resolution, 2 seems to be good, don't go too low or too high with this
	self.y_max_step = 1100 -- Greatest distance from the ground to an object: Mile High Club
	self.y_precision = 2 -- Number of decimal points to use when storing height data, 2 = cm precision
	self.ceiling = 2100 -- Maximum height: Gunung Raya, "Top of the World"
	self.sea_level = 200 -- Sea level height
	self.max_slope = 1 -- Maximum edge slope, 1 = 45 degrees
	self.path_height = 0.5 -- Line-of-sight check is at this height above the node
	self.radius = 0.05 -- Node render radius
	self.check_ceiling = false -- Whether to use raycasts during DFS to check for ceilings
	self.map_sea = true -- Whether to map sea nodes at all
	self.solid_sea = true -- Whether to map sea nodes at sea level or at undersea terrain
	self.interpolate_eight = true -- Whether to simulate eight-direction movement
	
	-- Node data structure
	-- [1] = center vector
	-- [2] = forward node
	-- [3] = backard node
	-- [4] = left node
	-- [5] = right node

	self:InitGraph()
	
	Events:Subscribe("Render", self, self.Render)
	Events:Subscribe("LocalPlayerChat", self, self.LocalPlayerChat)

end

function TerrainMap:InitGraph()

	self.graph = {}
	self.path = nil
	self.visited = nil
	self.render = nil
	self.show_points = nil
	self.show_lines = nil
	self.show_visited = nil
	self.start_node = nil
	self.goal_node = nil
	self.models = nil

end

function TerrainMap:LocalPlayerChat(args)

	local text = args.text:split(" ")
	local cmd = text[1]
	
	if cmd == "/getpos" then
		Chat:Print(tostring(LocalPlayer:GetPosition()), Color.Silver)
		return false
	end
	
	if cmd == "/getcell" then
		Chat:Print(string.format("Cell = (%i, %i)", self:GetCell(LocalPlayer:GetPosition())), Color.Silver)
		return false
	end	
	
	if cmd == "/tpcell" then
		self:TeleportToCell(tonumber(text[2]), tonumber(text[3]))
		return false
	end
	
	if cmd == "/mapcell" then
		self:BuildMap(self:GetCell(LocalPlayer:GetPosition()))
		self.render = true
		self.show_points = true
		return false
	end
	
	if cmd == "/processcell" then
		local cell_x, cell_y = self:GetCell(LocalPlayer:GetPosition())
		if self.graph[cell_x] and self.graph[cell_x][cell_y] then
			self:Process(cell_x, cell_y)
			self.show_points = false
			self.show_lines = true
		end
		return false
	end
	
	if cmd == "/unloadcell" then
		local cell_x, cell_y = self:GetCell(LocalPlayer:GetPosition())
		if self.graph[cell_x] then self.graph[cell_x][cell_y] = nil end
		if not next(self.graph[cell_x]) then self.graph[cell_x] = nil end
		return false
	end
	
	if cmd == "/dfs" then
		self:RemoveDisconnected()
		return false
	end

	if cmd == "/start" then
		self.start_node = self:GetNearestNode(LocalPlayer:GetPosition())
		return false
	end
	
	if cmd == "/goal" and self.start_node then
		self.goal_node = self:GetNearestNode(LocalPlayer:GetPosition())
		return false
	end
	
	if cmd == "/path" and self.start_node and self.goal_node then
		self.path, self.visited = self:FindPath(self.start_node, self.goal_node)
		self.show_lines = false
		self.show_points = false
		self.show_visited = true
		return false
	end
	
	if cmd == "/toggle8" then
		self.interpolate_eight = not self.interpolate_eight
		return false
	end
	
	if cmd == "/render" then
		self.render = not self.render
		return false
	end
	
	if cmd == "/points" then 
		self.show_points = not self.show_points
		return false
	end
	
	if cmd == "/lines" then
		self.show_lines = not self.show_lines
		return false
	end

	if cmd == "/visited" then
		self.show_visited = not self.show_visited
		return false
	end

	if cmd == "/deletenode" then
		self:DeleteNode(self:GetNearestNode(LocalPlayer:GetPosition()))
		return false
	end
	
	if cmd == "/mapterrain" then
		self:MapTerrain(tonumber(text[2]))
		self.render = true
		return false
	end
	
	if cmd == "/mem" then
		collectgarbage()
		collectgarbage()
		Chat:Print(string.format("%i kB used", collectgarbage("count")), Color.Silver)
		return false
	end
	
	if cmd == "/unload" then
		self:InitGraph()
		return false
	end

end

function TerrainMap:TeleportToCell(cell_x, cell_y)

	self.teleporting = true
	
	Chat:Print("----", Color.Silver)
	Chat:Print(string.format("Teleporting to Cell (%s, %s)", cell_x, cell_y), Color.Silver)
	
	self.previous_position = LocalPlayer:GetPosition()
	Waypoint:SetPosition(Vector3((cell_x + 1) * self.cell_size - 0.5 * self.cell_size - 16384, 0, (cell_y + 1) * self.cell_size - 0.5 * self.cell_size - 16384))

	Network:Send("TeleportToCell", {position = Waypoint:GetPosition()})
	self.terrain_load_event = Events:Subscribe("PostTick", self, self.TerrainLoad)

end

function TerrainMap:TerrainLoad()

	if self.teleporting then
		if LocalPlayer:GetPosition() ~= self.previous_position then
			self.previous_position = nil
			self.teleporting = nil
			self.terrain_loading = true
			Chat:Print("Teleport completed.", Color.Silver)
			Chat:Print("Loading terrain...", Color.Silver)
		end
	end
	
	if self.terrain_loading then
		if LocalPlayer:GetLinearVelocity() ~= Vector3.Zero then
			Chat:Print("Terrain loaded.", Color.Silver)
			Events:Unsubscribe(self.terrain_load_event)
			self.terrain_load_event = nil
			self.terrain_loading = nil
		end
	end

end

function TerrainMap:GetCell(position)

	return math.floor((position.x + 16384) / self.cell_size), math.floor((position.z + 16384) / self.cell_size)

end

function TerrainMap:IsLoaded(cell_x, cell_y)
	return self.graph[cell_x] and self.graph[cell_x][cell_y]
end

function TerrainMap:MapTerrain(step)

	local timer = Timer()

	self.models = {}
	
	for x = -16384, 16384, step or 256 do
		
		local vertices = {}
		for z = -16384, 16384, step or 256 do
			local y = Physics:GetTerrainHeight(Vector2(x, z))
			table.insert(vertices, Vertex(Vector3(x, y, z), self:GetColor(y)))
		end

		local model = Model.Create(vertices)
		model:SetTopology(Topology.LineStrip)
		table.insert(self.models, model)

	end
	
	for z = -16384, 16384, step or 256 do
		
		local vertices = {}
		for x = -16384, 16384, step or 256 do
			local y = Physics:GetTerrainHeight(Vector2(x, z))
			table.insert(vertices, Vertex(Vector3(x, y, z), self:GetColor(y)))
		end

		local model = Model.Create(vertices)
		model:SetTopology(Topology.LineStrip)
		table.insert(self.models, model)

	end
	
	print("Terrain time: "..tostring(timer:GetMilliseconds()).." ms")

end

function TerrainMap:GetColor(y)
	
	local color
	if y <= 200 then
		color = Color.FromHSV(math.lerp(240, 190, y / 200), 1, 1)
	else
		color = Color.FromHSV(math.lerp(120, 0, (y - 200) / 1900), 1, 1)
	end
	color.a = 128
	
	return color

end

function TerrainMap:BuildMap(cell_x, cell_y)

	local timer = Timer()
	
	local x_start = self.cell_size * cell_x - 16384
	local x_stop = x_start + self.cell_size - 1
	local z_start = self.cell_size * cell_y - 16384 
	local z_stop = z_start + self.cell_size - 1

	for x = x_start, x_stop, self.xz_step do
		for z = z_start, z_stop, self.xz_step do
			
			local ceiling_ray = Physics:Raycast(Vector3(x, self.ceiling, z), Vector3.Down, 0, self.ceiling)
			local max_y = math.round(ceiling_ray.position.y, self.y_precision)
			
			if (max_y <= self.sea_level and self.map_sea) or max_y > self.sea_level then
			
				if max_y <= self.sea_level and self.solid_sea then

					self:AddNode(x, self.sea_level, z)
					
				elseif max_y > self.sea_level or not self.solid_sea then
				
					self:AddNode(x, max_y, z)
				
					local terrain_height = Physics:GetTerrainHeight(Vector2(x, z))
					local terrain_ray = Physics:Raycast(Vector3(x, terrain_height, z), Vector3.Down, 0, terrain_height)
					local min_y = math.round(terrain_ray.position.y, self.y_precision)

					if max_y - min_y > self.y_min_step then
					
						local n = max_y - self.y_min_step

						repeat

							local ray = Physics:Raycast(Vector3(x, n, z), Vector3.Down, 0, self.y_max_step)
							if ray.distance > 0 and ray.distance < self.y_max_step then
								local y = math.round(ray.position.y, self.y_precision)
								if (y <= self.sea_level and self.map_sea) or y > self.sea_level then
									if y <= self.sea_level and self.solid_sea then
										self:AddNode(x, self.sea_level, z)
										break
									elseif y > self.sea_level or not self.solid_sea then
										self:AddNode(x, y, z)
									end
								end
								n = y - self.y_min_step
							else
								n = n - self.y_min_step
							end
							
						until n <= min_y
						
					end
					
				end
				
			end
	
		end
	end

	print(string.format("Map time: %i ms", timer:GetMilliseconds()))

end

function TerrainMap:VectorToNode(vector)

	local cell_x, cell_y = self:GetCell(vector)
	
	if self.graph[cell_x] and self.graph[cell_x][cell_y] and self.graph[cell_x][cell_y][vector.x] and self.graph[cell_x][cell_y][vector.x][vector.y] then
		return self.graph[cell_x][cell_y][vector.x][vector.z][math.round(vector.y, self.y_precision)]
	else
		return nil
	end

end

function TerrainMap:AddNode(x, y, z)

	local cell_x, cell_y = self:GetCell(Vector3(x, y, z))
	
	self.graph[cell_x] = self.graph[cell_x] or {}
	self.graph[cell_x][cell_y] = self.graph[cell_x][cell_y] or {}
	self.graph[cell_x][cell_y][x] = self.graph[cell_x][cell_y][x] or {}
	self.graph[cell_x][cell_y][x][z] = self.graph[cell_x][cell_y][x][z] or {}
	
	if not self.graph[cell_x][cell_y][x][z][y] then
		self.graph[cell_x][cell_y][x][z][y] = {Vector3(x, y, z)}
	end

end

function TerrainMap:LineOfSight(start_node, end_node)

	if math.abs(self:GetSlope(start_node, end_node)) > self.max_slope then return false end

	local distance = Vector3.Distance(start_node[1], end_node[1])
	local ray1 = Physics:Raycast(start_node[1] + Vector3.Up * self.path_height, (end_node[1] - start_node[1]), 0, distance)
	local ray2 = Physics:Raycast(end_node[1] + Vector3.Up * self.path_height, (start_node[1] - end_node[1]), 0, distance)
	
	return not (ray1.distance < distance or ray2.distance < distance)
	
end

function TerrainMap:GetSlope(start_node, end_node)

	local rise = end_node[1].y - start_node[1].y
	local run = Vector3.Distance2D(start_node[1], end_node[1])
	
	return rise / run

end

function TerrainMap:Process(cell_x, cell_y)
	
	local timer = Timer()

	for x, v in pairs(self.graph[cell_x][cell_y]) do
		for z, v in pairs(v) do
			for y, start_node in pairs(v) do
				
				local step = self.xz_step

				local f_cell_x, f_cell_y = self:GetCell(Vector3(x, y, z-step))
				local b_cell_x, b_cell_y = self:GetCell(Vector3(x, y, z+step))
				local l_cell_x, l_cell_y = self:GetCell(Vector3(x-step, y, z))
				local r_cell_x, r_cell_y = self:GetCell(Vector3(x+step, y, z))
				
				local f_cell, b_cell, l_cell, r_cell
				
				if self.graph[f_cell_x] and self.graph[f_cell_x][f_cell_y] then
					f_cell = self.graph[f_cell_x][f_cell_y]
				end
				
				if self.graph[b_cell_x] and self.graph[b_cell_x][b_cell_y] then
					b_cell = self.graph[b_cell_x][b_cell_y]
				end
				
				if self.graph[l_cell_x] and self.graph[l_cell_x][l_cell_y] then
					l_cell = self.graph[l_cell_x][l_cell_y]
				end
				
				if self.graph[r_cell_x] and self.graph[r_cell_x][r_cell_y] then
					r_cell = self.graph[r_cell_x][r_cell_y]
				end
				
				if r_cell and r_cell[x+step] and r_cell[x+step][z] and not start_node[5] then
					for n, right in pairs(r_cell[x+step][z]) do
						local end_node = right
						if y == self.sea_level and n == self.sea_level then
							start_node[5] = end_node
							end_node[4] = start_node
						elseif self:LineOfSight(start_node, end_node) then
							start_node[5] = end_node
							end_node[4] = start_node
						end
					end
				end

				if l_cell and l_cell[x-step] and l_cell[x-step][z] and not start_node[4] then
					for n, left in pairs(l_cell[x-step][z]) do
						local end_node = left
						if y == self.sea_level and n == self.sea_level then
							start_node[4] = end_node
							end_node[5] = start_node
						elseif self:LineOfSight(start_node, end_node) then
							start_node[4] = end_node
							end_node[5] = start_node
						end
					end
				end

				if b_cell and b_cell[x][z+step] and not start_node[3] then
					for n, backward in pairs(b_cell[x][z+step]) do
						local end_node = backward
						if y == self.sea_level and n == self.sea_level then
							start_node[3] = end_node
							end_node[2] = start_node
						elseif self:LineOfSight(start_node, end_node) then
							start_node[3] = end_node
							end_node[2] = start_node
						end
					end
				end
				
				if f_cell and f_cell[x][z-step] and not start_node[2] then
					for n, forward in pairs(f_cell[x][z-step]) do
						local end_node = forward
						if y == self.sea_level and n == self.sea_level then
							start_node[2] = end_node
							end_node[3] = start_node
						elseif self:LineOfSight(start_node, end_node) then
							start_node[2] = end_node
							end_node[3] = start_node
						end
					end
				end
					
			end
							
		end
		collectgarbage()
	end
	
	print(string.format("Map time: %i ms", timer:GetMilliseconds()))

end

function TerrainMap:GetNearestNode(position)

	local nearest_distance = math.huge
	local nearest_node = nil
	
	local cell_x, cell_y = self:GetCell(position)
	
	if self.graph[cell_x] and self.graph[cell_x][cell_y] then
	
		local x = math.round(position.x)
		local z = math.round(position.z)

		while next(self.graph[cell_x][cell_y]) and not self.graph[cell_x][cell_y][x] do
			x = x - 1
		end
		
		while next(self.graph[cell_x][cell_y][x]) and not self.graph[cell_x][cell_y][x][z] do
			z = z - 1
		end

		for y, node in pairs(self.graph[cell_x][cell_y][x][z]) do
				
			local distance = Vector3.DistanceSqr(position, node[1])
			if distance < nearest_distance then
				nearest_distance = distance
				nearest_node = node
			end

		end
		
	end
		
	return nearest_node
	
end

function TerrainMap:GetNearestNodeBruteForce(position)

	local nearest_distance = math.huge
	local nearest_node = nil
	
	local cell_x, cell_y = self:GetCell(position)
	
	if self.graph[cell_x] then
		for x, v in pairs(self.graph[cell_x][cell_y]) do
			for z, v in pairs(v) do
				for y, node in pairs(v) do
			
					local distance = Vector3.DistanceSqr(position, node[1])
					if distance < nearest_distance then
						nearest_distance = distance
						nearest_node = node
					end
					
				end
			end
		end
	end
		
	return nearest_node

end

function TerrainMap:RemoveDisconnected()

	local timer = Timer()

	local start = self:GetNearestNode(LocalPlayer:GetPosition())
	local visited = {}
	local connected = {[start] = true}
	local s = {start}
	
	while #s > 0 do

		for _, neighbor in ipairs(self:GetNeighbors(table.remove(s))) do			
			if not connected[neighbor] then
				table.insert(s, neighbor)
				connected[neighbor] = true
			end
		end
		
	end
	
	for cell_x, v in pairs(self.graph) do
		for cell_y, v in pairs(v) do
			for x, v in pairs(v) do
				for z, v in pairs(v) do
					for y, node in pairs(v) do
		
						if not connected[node] then
					
							if self.check_ceiling then
					
								local distance = self.ceiling - node[1].y
							
								local ray = Physics:Raycast(node[1] + Vector3.Up * self.path_height, Vector3.Up, 0, distance)
							
								if ray.distance < distance then
									self:DeleteNode(node)
								end
							
							else

								self:DeleteNode(node)

							end
			
						end

					end
				end
			end
		end
	end
	
	print(string.format("DFS time: %i ms", timer:GetMilliseconds()))
				
end

function TerrainMap:DeleteNode(node)

	local cell_x, cell_y = self:GetCell(node[1])
	
	if node[2] then node[2][3] = nil end
	if node[3] then node[3][2] = nil end
	if node[4] then node[4][5] = nil end
	if node[5] then node[5][4] = nil end
	
	local x = node[1].x
	local z = node[1].z
	local y = math.round(node[1].y, self.y_precision)
	
	self.graph[cell_x][cell_y][x][z][y] = nil
	
	if not next(self.graph[cell_x][cell_y][x][z]) then
		self.graph[cell_x][cell_y][x][z] = nil
		if not next(self.graph[cell_x][cell_y][x]) then
			self.graph[cell_x][cell_y][x] = nil
			if not next(self.graph[cell_x][cell_y]) then
				self.graph[cell_x][cell_y] = nil
				if not next(self.graph[cell_x]) then
					self.graph[cell_x] = nil
				end
			end
		end
	end

end

function TerrainMap:FindPath(start, goal)

	local timer = Timer()
	
	local frontier = {}
	local visited = {}
	local came_from = {}
	local cost_so_far = {}
	local priority = {}
	
	cost_so_far[start] = 0
	priority[start] = cost_so_far[start] + self:GetHeuristicCost(start, goal)
	frontier[start] = true
	
	while next(frontier) do
	
		-- Priority queue implementation
		local lowest = math.huge
		local current = nil
		for node in pairs(frontier) do
			if priority[node] < lowest then
				lowest = priority[node]
				current = node
			end
		end
		
		frontier[current] = nil
		visited[current] = true
		
		if current == goal then
		
			print(string.format("A* time: %i ms", timer:GetMilliseconds()))

			local path = {current}
			
			while came_from[current] do
				current = came_from[current]
				table.insert(path, current)
			end
			
			return path, visited
			
		end

		for _, neighbor in ipairs(self:GetNeighbors(current)) do

			if not visited[neighbor] then

				local new_cost = cost_so_far[current] + self:GetConnectedCost(current, neighbor)
				if not frontier[neighbor] or new_cost < cost_so_far[neighbor] then
					came_from[neighbor] = current
					cost_so_far[neighbor] = new_cost
					frontier[neighbor] = true
					priority[neighbor] = cost_so_far[neighbor] + self:GetHeuristicCost(neighbor, goal)
				end
				
			end
			
		end
		
	end

end

function TerrainMap:GetHeuristicCost(start_node, end_node)

	return Vector3.Distance(start_node[1], end_node[1])
		
end

function TerrainMap:GetConnectedCost(start_node, end_node)

	local weight = 1
	
	if end_node[1].y == self.sea_level then
		weight = 2 * weight
	end
	
	return weight * Vector3.Distance(start_node[1], end_node[1])

end

function TerrainMap:GetNeighbors(node)

	local neighbors = {}
	
	if node[2] then -- forward
		table.insert(neighbors, node[2])
	end
	
	if node[3] then -- backward
		table.insert(neighbors, node[3])
	end
	
	if node[4] then -- left
		table.insert(neighbors, node[4])
	end
	
	if node[5] then -- right
		table.insert(neighbors, node[5])
	end
	
	if self.interpolate_eight then
	
		if node[2] and node[4] and node[2][4] and node[4][2] then
			table.insert(neighbors, node[2][4])
		end
		
		if node[2] and node[5] and node[2][5] and node[5][2] then
			table.insert(neighbors, node[2][5])
		end
		
		if node[3] and node[4] and node[3][4] and node[4][3] then
			table.insert(neighbors, node[3][4])
		end
		
		if node[3] and node[5] and node[3][5] and node[5][3] then
			table.insert(neighbors, node[3][5])
		end
		
	end

	return neighbors

end

function TerrainMap:Render()

	if Game:GetState() ~= 4 or not self.render then return end

	if self.models then
		for _, model in ipairs(self.models) do
			model:Draw()
		end
	end
		
	if self.show_points or self.show_lines then
		self:DrawGraph(self.graph, Color.Lime)
	end
	
	if self.path then
		for i, node in ipairs(self.path) do
			if self.path[i+1] then
				Render:DrawLine(node[1] + Vector3.Up * self.path_height, self.path[i+1][1] + Vector3.Up * self.path_height, Color.Magenta)
			end
		end
		
		if self.show_visited then
			for node in pairs(self.visited) do
				Render:DrawCircle(node[1] + Vector3(0, 0.5 * self.path_height, 0), self.radius, Color.Cyan)
			end
		end
	end
	
	if self.start_node then
		Render:DrawCircle(self.start_node[1] + Vector3(0, self.path_height, 0), 2 * self.radius, Color.Magenta)
	end
	
	if self.goal_node then
		Render:DrawCircle(self.goal_node[1] + Vector3(0, self.path_height, 0), 2 * self.radius, Color.Magenta)
	end	
	
end

function TerrainMap:DrawGraph(graph, color)

	for cell_x, v in pairs(self.graph) do
		for cell_y, v in pairs(v) do
			for x, v in pairs(v) do
				for z, v in pairs(v) do
					for y, node in pairs(v) do
			
						if self.show_points then		
							Render:DrawCircle(node[1], self.radius, color)
						end
						
						if self.show_lines then

							if node[3] then
								Render:DrawLine(node[1], node[3][1], color)
							end
							
							if node[5] then
								Render:DrawLine(node[1], node[5][1], color)
							end

						end
						
					end
				end
			end			
		end
	end

end

TerrainMap = TerrainMap()
