class 'TerrainMap'

function TerrainMap:__init()

	Network:Subscribe("TeleportToCell", self, self.TeleportToCell)
	
end

function TerrainMap:TeleportToCell(args, sender)

	sender:SetPosition(args.position + Vector3(0, 20, 0))

end

TerrainMap = TerrainMap()
