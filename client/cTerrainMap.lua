local math, string, table = math, string, table
local pairs, ipairs, next = pairs, ipairs, next
local max, min, abs, sqrt = math.max, math.min, math.abs, math.sqrt
local create, yield, resume = coroutine.create, coroutine.yield, coroutine.resume
local floor, round = math.floor, math.round
local format, split = string.format, string.split
local insert = table.insert
local band = bit32.band
local huge = math.huge
local config = config

local distances = {}

function distances.manhattan(a, b)
	local dx = abs(b.x - a.x)
	local dy = abs(b.y - a.y)
	local dz = abs(b.z - a.z)
	return dx + dy + dz
end

local diff = sqrt(2) - 2
function distances.diagonal(a, b)
	local dx = abs(b.x - a.x)
	local dy = abs(b.y - a.y)
	local dz = abs(b.z - a.z)
	return dx + dy + dz + diff * min(dx, dy, dz)
end

function distances.euclidean(a, b)
	return a:Distance(b)
end

function distances.euclideanSqr(a, b)
	return a:DistanceSqr(b)
end

class 'TerrainMap'

function TerrainMap:__init()

	self:InitGraph()

	local directions = {
		{0x01, 0,-1}, -- forward
		{0x02, 0, 1}, -- backward
		{0x04,-1, 0}, -- left
		{0x08, 1, 0}, -- right
	}

	if config.eight then
		insert(directions, {0x10,-1,-1}) -- forward left
		insert(directions, {0x20, 1, 1}) -- backward right
		insert(directions, {0x40, 1,-1}) -- forward right
		insert(directions, {0x80,-1, 1}) -- backward left
	end

	self.directions = directions

	Events:Subscribe('Render', self, self.OnRender)
	Events:Subscribe('PlayerChat', self, self.OnPlayerChat)

	Network:Subscribe('CellSaved', self, self.ReadyThread)
	Network:Subscribe('CellLoaded', self, self.OnLoadedCell)

end

function TerrainMap:InitGraph()
	self.graph, self.models = {}, {}
	self.thread, self.ready = nil, nil
	self.start, self.stop = nil, nil
	self.path, self.visited = nil, nil
	self.path_offset = Vector3.Up * config.path_height
end

function TerrainMap:OnPlayerChat(args)

	local text = split(args.text, ' ')
	local cmd = text[1]

	if cmd == "/getpos" then
		Chat:Print(tostring(LocalPlayer:GetPosition()), Color.Silver)
		return false
	end

	if cmd == '/getcell' then
		local pos = LocalPlayer:GetPosition()
		Chat:Print(format('Cell = (%i, %i)', self:GetCellXY(pos.x, pos.z)), Color.Silver)
		return false
	end

	if cmd == '/tpcell' then
		local cell_x, cell_y = tonumber(text[2]), tonumber(text[3])
		if cell_x and cell_y then self:TeleportToCell(cell_x, cell_y) end
		return false
	end

	if cmd == '/mapcell' then
		local pos = LocalPlayer:GetPosition()
		local timer = Timer()
		local cell_x, cell_y = self:GetCellXY(pos.x, pos.z)
		self:MapCell(cell_x, cell_y)
		printf('Map time: %i ms', timer:GetMilliseconds())
		timer:Restart()
		self:BuildPointModel(cell_x, cell_y)
		printf('Point model time: %i ms', timer:GetMilliseconds())
		return false
	end

	if cmd == '/processcell' then
		local pos = LocalPlayer:GetPosition()
		local timer = Timer()
		local cell_x, cell_y = self:GetCellXY(pos.x, pos.z)
		self:ProcessCell(cell_x, cell_y)
		printf('Process time: %i ms', timer:GetMilliseconds())
		timer:Restart()
		self:BuildLineModel(cell_x, cell_y)
		printf('Line model time: %i ms', timer:GetMilliseconds())
		return false
	end

	if cmd == '/savecell' then
		local pos = LocalPlayer:GetPosition()
		self:SaveCell(self:GetCellXY(pos.x, pos.z))
		return false
	end

	if cmd == '/loadcell' then
		local pos = LocalPlayer:GetPosition()
		self:LoadCell(self:GetCellXY(pos.x, pos.z))
		return false
	end

	if cmd == '/land' then
		local pos = LocalPlayer:GetPosition()
		local has_land = self:CellHasLand(self:GetCellXY(pos.x, pos.z))
		Chat:Print(tostring(has_land), Color.Silver)
		return false
	end

	if cmd == '/automap' then
		if not self.thread then
			Game:FireEvent('ply.makeinvulnerable')
			local pos = LocalPlayer:GetPosition()
			self:AutoMap(self:GetCellXY(pos.x, pos.z))
		else
			Game:FireEvent('ply.makevulnerable')
			self.thread, self.ready = nil, nil
		end
		return false
	end

	if cmd == "/mem" then
		local mem = self:GetMemoryUsage()
		Chat:Print(format("%i kB used", mem), Color.Silver)
		return false
	end

	if cmd == '/unload' then
		self:InitGraph()
		return false
	end

	if cmd == '/start' then
		self.start = self:GetNearestNode(LocalPlayer:GetPosition())
		return false
	end

	if cmd == '/stop' then
		self.stop = self:GetNearestNode(LocalPlayer:GetPosition())
		return false
	end

	if cmd == '/path' then
		assert(self.start, 'Start node not selected')
		assert(self.stop, 'Stop node not selected')
		self.path, self.visited = self:GetPath(self.start, self.stop)
		return false
	end

end

function TerrainMap:GetMemoryUsage()
	collectgarbage()
	collectgarbage()
	return collectgarbage("count")
end

function TerrainMap:GetCenterOfCell(cell_x, cell_y)
	local size = config.cell_size
	local x = cell_x * size + 0.5 * size - 16384
	local z = cell_y * size + 0.5 * size - 16384
	local pos = Vector3(x, 0, z)
	pos.y = max(Physics:GetTerrainHeight(pos), 200)
	return pos
end

function TerrainMap:GetCellXY(x, z)
	local size = config.cell_size
	return floor((x + 16384) / size), floor((z + 16384) / size)
end

function TerrainMap:GetCell(x, z)
	local graph = self.graph
	local cell_x, cell_y = self:GetCellXY(x, z)
	return graph[cell_x] and graph[cell_x][cell_y]
end

function TerrainMap:TeleportToCell(cell_x, cell_y)
	Chat:Print(format('Teleporting to cell (%i, %i)...', cell_x, cell_y), Color.Silver)
	return self:TeleportToPosition(self:GetCenterOfCell(cell_x, cell_y))
end

function TerrainMap:TeleportToPosition(position)

	self.previous = LocalPlayer:GetPosition()
	local zero, sub = Vector3.Zero, nil
	sub = Events:Subscribe('PreTick', function()
		if self.previous then
			if LocalPlayer:GetPosition() ~= self.previous then
				self.loading, self.previous = Timer(), nil
				Chat:Print('Teleport completed, loading terrain ...', Color.Silver)
			end
		elseif self.loading then
			if LocalPlayer:GetLinearVelocity() ~= zero or self.loading:GetSeconds() > 5 then
				Chat:Print('Terrain loaded.', Color.Silver)
				Events:Unsubscribe(sub)
				self.loading = nil
				self:ReadyThread()
			end
		end
	end)
	Network:Send('TeleportToPosition', {position = position})

end

function TerrainMap:CellHasLand(cell_x, cell_y)
	local size = config.cell_size
	local sea_level = config.sea_level
	local step = size
	repeat
		local x_start, x_stop, z_start, z_stop = self:GetCellCorners(cell_x, cell_y)
		for x = x_start, x_stop, step do
			for z = z_start, z_stop, step do
				if Physics:GetTerrainHeight(Vector2(x, z)) > sea_level then
					return true
				end
			end
		end
		step = step / 2
	until step < config.xz_step
	return false
end

function TerrainMap:GetCellCorners(cell_x, cell_y)
	local size = config.cell_size
	local x_start = size * cell_x - 16384
	local x_stop = x_start + size - 1
	local z_start = size * cell_y - 16384
	local z_stop = z_start + size - 1
	return x_start, x_stop, z_start, z_stop
end

function TerrainMap:MapCell(cell_x, cell_y)
	if self.graph[cell_x] and self.graph[cell_x][cell_y] then return end
	return self:BuildMap(self:GetCellCorners(cell_x, cell_y))
end

function TerrainMap:BuildMap(x_start, x_stop, z_start, z_stop)

	local step = config.xz_step
	local y_min_step, y_max_step = config.y_min_step, config.y_max_step
	local ceiling = config.ceiling
	local sea_level = config.sea_level
	local map_sea_nodes, solid_sea = config.map_sea_nodes, config.solid_sea
	local down = Vector3.Down
	local round = round

	for x = x_start, x_stop, step do
		for z = z_start, z_stop, step do
			local ceiling_ray = Physics:Raycast(Vector3(x, ceiling, z), down, 0, ceiling)
			local max_y = round(ceiling_ray.position.y, 2)
			if (max_y <= sea_level and map_sea_nodes) or max_y > sea_level then
				if max_y <= sea_level and solid_sea then
					self:AddNode(x, sea_level, z)
				elseif max_y > sea_level or not solid_sea then
					self:AddNode(x, max_y, z)
					local terrain_height = Physics:GetTerrainHeight(Vector2(x, z))
					local terrain_ray = Physics:Raycast(Vector3(x, terrain_height, z), down, 0, terrain_height)
					local min_y = round(terrain_ray.position.y, 2)
					if max_y - min_y > y_min_step then
						local n = max_y - y_min_step
						repeat
							local ray = Physics:Raycast(Vector3(x, n, z), down, 0, y_max_step)
							if ray.distance > 0 and ray.distance < y_max_step then
								local y = round(ray.position.y, 2)
								if (y <= sea_level and map_sea_nodes) or y > sea_level then
									if y <= sea_level and solid_sea then
										self:AddNode(x, sea_level, z)
										break
									elseif y > sea_level or not solid_sea then
										self:AddNode(x, y, z)
									end
								end
								n = y - y_min_step
							else
								n = n - y_min_step
							end
						until n <= min_y
					end
				end
			end
		end
	end

end

function TerrainMap:AddNode(x, y, z)

	local cell_x, cell_y = self:GetCellXY(x, z)
	local graph = self.graph

	graph[cell_x] = graph[cell_x] or {}
	graph[cell_x][cell_y] = graph[cell_x][cell_y] or {}
	graph[cell_x][cell_y][x] = graph[cell_x][cell_y][x] or {}
	graph[cell_x][cell_y][x][z] = graph[cell_x][cell_y][x][z] or {}
	graph[cell_x][cell_y][x][z][y] = Vector3(x, y, z)

end

function TerrainMap:BuildPointModel(cell_x, cell_y)

	local graph = self.graph
	local cell = graph[cell_x] and graph[cell_x][cell_y]
	if not cell then return end
	local vertices = {}
	for x, v in pairs(cell) do
		for z, v in pairs(v) do
			for y, node in pairs(v) do
				insert(vertices, Vertex(node))
			end
		end
	end

	if #vertices > 0 then
		local model = Model.Create(vertices)
		if (cell_x + cell_y) % 2 == 0 then
			model:SetColor(config.graph_color1)
		else
			model:SetColor(config.graph_color2)
		end
		model:SetTopology(Topology.PointList)
		local models = self.models
		models[cell_x] = models[cell_x] or {}
		models[cell_x][cell_y] = model
	end

end

function TerrainMap:ProcessCell(cell_x, cell_y)

	local graph = self.graph
	if not graph[cell_x] or not graph[cell_x][cell_y] then return end

	local step = config.xz_step
	local sea_level = config.sea_level
	local directions = self.directions

	for x, v in pairs(graph[cell_x][cell_y]) do
		for z, v in pairs(v) do
			for y, start_node in pairs(v) do
				local n = 0
				for i, direction in ipairs(self.directions) do
					local n_x = x + step * direction[2]
					local n_z = z + step * direction[3]
					local n_cell = self:GetCell(n_x, n_z)
					local n_xz = n_cell and n_cell[n_x] and n_cell[n_x][n_z]
					if n_xz then
						for n_y, end_node in pairs(n_xz) do
							if y == sea_level and y == n_y or self:LineOfSight(start_node, end_node) then
								n = n + direction[1]
								break
							end
						end
					end
				end
				start_node.n = n
			end
		end
	end

end

function TerrainMap:BuildLineModel(cell_x, cell_y)

	local graph = self.graph
	local cell = graph[cell_x] and graph[cell_x][cell_y]
	if not cell then return end
	local vertices = {}
	for x, v in pairs(cell) do
		for z, v in pairs(v) do
			for y, node in pairs(v) do
				local center = Vertex(node)
				for i, neighbor in ipairs(self:GetNeighbors(node)) do
					insert(vertices, center)
					insert(vertices, Vertex(neighbor))
				end
			end
		end
	end

	if #vertices > 0 then
		local model = Model.Create(vertices)
		if (cell_x + cell_y) % 2 == 0 then
			model:SetColor(config.graph_color1)
		else
			model:SetColor(config.graph_color2)
		end
		model:SetTopology(Topology.LineList)
		local models = self.models
		models[cell_x] = models[cell_x] or {}
		models[cell_x][cell_y] = model
	end

end

function TerrainMap:GetNeighbors(node)

	local neighbors = {}
	local step = config.xz_step
	local x, y, z, n = node.x, node.y, node.z, node.n
	for _, direction in ipairs(self.directions) do
		if band(n, direction[1]) > 0 then
			local next_x, next_z = x + direction[2] * step, z + direction[3] * step
			local next_cell = self:GetCell(next_x, next_z)
			local neighbor_xz = next_cell and next_cell[next_x] and next_cell[next_x][next_z]
			if neighbor_xz then
				-- need to find a valid y value in the neighboring node(s)
				local nearest_distance, nearest_node = huge
				for other_y, other_node in pairs(neighbor_xz) do
					local distance = abs(other_y - y)
					if distance < nearest_distance then
						nearest_distance = distance
						nearest_node = other_node
					end
				end
				insert(neighbors, nearest_node)
			end
		end
	end

	return neighbors

end

function TerrainMap:LineOfSight(p1, p2)

	if abs(self:GetSlope(p1, p2)) > config.max_slope then return false end

	local d = p1:Distance(p2)

	if Physics:Raycast(p1 + self.path_offset, p2 - p1, 0, d).distance < d then return false end
	if Physics:Raycast(p2 + self.path_offset, p1 - p2, 0, d).distance < d then return false end

	return true

end

function TerrainMap:GetSlope(p1, p2)
	return (p2.y - p1.y) / p1:Distance2D(p2)
end

function TerrainMap:SaveCell(cell_x, cell_y)

	self.graph = {}

	self:MapCell(cell_x, cell_y)

	for _, direction in ipairs(self.directions) do
		self:MapCell(cell_x + direction[2], cell_y + direction[3])
	end

	self:ProcessCell(cell_x, cell_y)

	local size, step = config.cell_size, config.xz_step
	local root_x, root_z = 16384 - cell_x * size, 16384 - cell_y * size
	local sea_level = config.sea_level
	local save_sea_cells = config.save_sea_cells

	local nodes = {}
	local count = 0
	local graph = self.graph

	local has_land = false
	if graph[cell_x] and graph[cell_x][cell_y] then
		for x, v in pairs(graph[cell_x][cell_y]) do
			for z, v in pairs(v) do
				for y, node in pairs(v) do
					if node.n > 0 then -- ignore nodes with no connections
						count = count + 1
						local x = (x + root_x) / step
						local z = (z + root_z) / step
						local y = round(y) -- round to save space
						if y ~= sea_level then has_land = true end
						nodes[x] = nodes[x] or {}
						nodes[x][z] = nodes[x][z] or {}
						nodes[x][z][y] = node.n
					end
				end
			end
		end
	end

	if not save_sea_cells and not has_land then nodes = nil end

	Network:Send('SaveCell', {
		nodes = nodes, count = count,
		cell_x = cell_x, cell_y = cell_y,
	})

	self.graph = {}

end

function TerrainMap:LoadCell(cell_x, cell_y)
	self.load_timer = Timer()
	Network:Send('LoadCell', {
		cell_x = cell_x, cell_y = cell_y
	})
end

function TerrainMap:OnLoadedCell(args)

	local graph = self.graph
	local cell_x, cell_y = args.cell_x, args.cell_y
	local step = config.xz_step

	graph[cell_x] = {[cell_y] = {}}

	if args.nodes then

		local size = config.cell_size
		local root_x, root_z = 16384 - cell_x * size, 16384 - cell_y * size

		for _, node in ipairs(args.nodes) do
			local x = node[1] * step - root_x
			local z = node[2] * step - root_z
			local y = node[3]
			local v = Vector3(x, y, z); v.n = node[4]
			graph[cell_x][cell_y][x] = graph[cell_x][cell_y][x] or {}
			graph[cell_x][cell_y][x][z] = graph[cell_x][cell_y][x][z] or {}
			graph[cell_x][cell_y][x][z][y] = v
		end

	else

		local sea_level = config.sea_level
		local x_start, x_stop, z_start, z_stop = self:GetCellCorners(cell_x, cell_y)

		for x = x_start, x_stop, step do
			graph[cell_x][cell_y][x] = {}
			for z = z_start, z_stop, step do
				local v = Vector3(x, sea_level, z); v.n = 255
				graph[cell_x][cell_y][x][z] = {[sea_level] = v}
			end
		end

	end

	printf('Cell load time: %i ms', self.load_timer:GetMilliseconds())
	self:BuildLineModel(cell_x, cell_y)

end

function TerrainMap:AutoMap(cell_x, cell_y)
	self.ready = false
	self.thread = create(function()
		local save_sea_cells = config.save_sea_cells
		local n = 32768 / config.cell_size - 1
		for cell_x = 0, n do
			for cell_y = 0, n do
				if save_sea_cells or self:CellHasLand(cell_x, cell_y) then
					yield(self:TeleportToCell(cell_x, cell_y))
					yield(self:SaveCell(cell_x, cell_y))
				end
			end
		end
	end)
	resume(self.thread)
end

function TerrainMap:ReadyThread()
	if self.thread then self.ready = true end
end

function TerrainMap:GetNearestNode(position)

	local step = config.xz_step
	local x = floor(position.x / step + 0.5) * step
	local z = floor(position.z / step + 0.5) * step
	local cell = self:GetNearestCell(position)

	if cell[x] and cell[x][z] then
		local nearest_distance, nearest_node = huge
		for y, node in pairs(cell[x][z]) do
			local distance = abs(y - position.y)
			if distance < nearest_distance then
				nearest_distance = distance
				nearest_node = node
			end
		end
		if nearest_node then return nearest_node end
	end

	local nearest_distance, nearest_node = huge
	for x, v in pairs(cell) do
		for z, v in pairs(v) do
			for y, node in pairs(v) do
				local distance = position:DistanceSqr(node[1])
				if distance < nearest_distance then
					nearest_distance = distance
					nearest_node = node
				end
			end
		end
	end

	assert(nearest_node, 'No node discovered')
	return nearest_node

end

function TerrainMap:GetNearestCell(position)

	local nearest_cell = self:GetCell(position.x, position.z)

	if not nearest_cell then
		local graph = self.graph
		local nearest_distance, nearest_x, nearest_y = huge
		for cell_x, v in pairs(graph) do
			for cell_y in pairs(v) do
				local center = self:GetCenterOfCell(cell_x, cell_y)
				local distance = position:DistanceSqr(center)
				if distance < nearest_distance then
					nearest_distance = distance
					nearest_x, nearest_y = cell_x, cell_y
				end
			end
		end
		nearest_cell = graph[nearest_x] and graph[nearest_x][nearest_y]
	end

	assert(nearest_cell, 'No cell discovered')
	return nearest_cell

end

function TerrainMap:GetPath(start, goal)

	local timer = Timer()

	local frontier, visited = {}, {}
	local came_from, cost_so_far = {}, {}

	cost_so_far[start] = 0
	frontier[start] = self:GetHeuristicCost(start, goal)

	while next(frontier) do

		local lowest = huge
		local current = nil
		for node, priority in pairs(frontier) do
			if priority < lowest then
				lowest = priority
				current = node
			end
		end

		frontier[current] = nil
		visited[current] = true

		if current == goal then
			local path = {current}
			while came_from[current] do
				current = came_from[current]
				insert(path, current)
			end
			printf("A* time: %i ms", timer:GetMilliseconds())
			return path, visited
		end

		for _, neighbor in ipairs(self:GetNeighbors(current)) do
			if not visited[neighbor] then
				local new_cost = cost_so_far[current] + self:GetConnectedCost(current, neighbor)
				if not frontier[neighbor] or new_cost < cost_so_far[neighbor] then
					came_from[neighbor] = current
					cost_so_far[neighbor] = new_cost
					frontier[neighbor] = new_cost + self:GetHeuristicCost(neighbor, goal)
				end
			end
		end

	end

	return nil, visited

end

function TerrainMap:GetHeuristicCost(start_node, end_node)
	return distances.diagonal(start_node, end_node) -- change for different results
end

function TerrainMap:GetConnectedCost(start_node, end_node)
	local weight = end_node.y == self.sea_level and 2 or 1
	return weight * start_node:Distance(end_node)
end

function TerrainMap:OnRender()

	if Game:GetState() ~= 4 then return end

	for cell_x, v in pairs(self.models) do
		for cell_y, model in pairs(v) do
			model:Draw()
		end
	end

	local offset = self.path_offset
	local path_color = config.path_color
	local visited_color = config.visited_color

	if self.start then Render:DrawCircle(self.start + offset, 0.5, path_color) end
	if self.stop then Render:DrawCircle(self.stop + offset, 0.5, path_color) end

	if self.path then
		local path = self.path
		for i = 1, #path - 1 do
			local a = path[i] + offset
			local b = path[i + 1] + offset
			Render:DrawLine(a, b, path_color)
		end
	end

	if self.visited then
		for node in pairs(self.visited) do
			Render:DrawCircle(node, 0.2, visited_color)
		end
	end

	if self.thread and self.ready then
		self.ready = false
		assert(resume(self.thread))
	end

end

TerrainMap = TerrainMap()
